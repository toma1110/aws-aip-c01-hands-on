# Guardrails・合成PII・IAMを重ねて情報漏えい経路を塞ぐ

## このハンズオンで解決する課題

Amazon Bedrock Guardrailsをモデル出力へ適用しても、アプリケーションログ、外部ツールへ渡す引数、検索した参照文書は自動的には保護されません。この演習では実在しないメールアドレスと演習専用識別子だけを使い、4つの経路を比較します。モデル入力の検査は今回の範囲外です。

- モデル出力
- アプリケーションログ
- 外部ツールの引数
- 検索した参照文書

改善後は、Guardrailsの独立API、アプリケーション側の伏せ字化と非保存、特定Guardrailだけを許可するIAMポリシーを組み合わせます。

## 安全境界

- `john@example.com`と`SYNTH-KEY-4821`は、予約済みexample domainと演習専用形式を使った合成データです。実際の個人情報、アクセスキー、credential、業務データを入力しないでください。
- モデル推論は行いません。`ApplyGuardrail`はGuardrailsをアプリケーションフロー内で独立して評価するAPIです。
- AWS上で作るresourceはGuardrail 1件だけです。IAM role/policy、CloudWatch log group、KMS key/grantは作りません。
- IAMは`simulate-custom-policy`で、対象Guardrailは許可、別resourceは暗黙的拒否になることを評価します。
- scriptは終了時にGuardrailを削除します。CloudTrailなど、この演習が作成していない共通記録は削除しません。

## 前提とRegion

- AWS Consoleへサインインし、CloudShellを利用できること
- Regionは`us-east-1`
- CloudShellのAWS CLI、Python 3、`jq`
- `bedrock:CreateGuardrail`、`bedrock:CreateGuardrailVersion`、`bedrock:GetGuardrail`、`bedrock:ListGuardrails`、`bedrock:DeleteGuardrail`、`bedrock:ApplyGuardrail`、`iam:SimulateCustomPolicy`、`sts:GetCallerIdentity`

Guardrails作成時にtagを指定しないため、`bedrock:TagResource`は不要です。組織のSCP、permission boundary、session policyで上記操作が制限されている場合は管理者へ確認してください。

## 料金とquota

Guardrailsは評価したtext unitごとの従量料金です。この演習は短い出力を1回だけ評価し、モデル推論、ログ保存、KMS customer managed keyを使用しません。通常はごく少額ですが、実行前に[Amazon Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)のGuardrails欄と、Service QuotasのAmazon Bedrockを確認してください。2026-08-12に`us-east-1`でread-only確認したquotaはApplyGuardrail 100 requests/second、Sensitive information filter 1,000 text units/second、最大入力1,000 text unitsでした。この演習の実測は1 request・1 sensitive-information text unitで範囲内です。quotaと価格は変更されるため、実行時の値も確認してください。

## 1. ローカルで漏えい経路を観察する

ここで動かす`h3.scenario`は、入力に対して同じ結果を返す決定的なPython simulationです。`improved`もAmazon Bedrock Guardrailsを呼び出す処理ではなく、4経路をアプリケーション側で伏せ字化・非保存にしたときの比較結果です。実際のGuardrails APIは次のCloudShell手順で確認します。

このREADMEのディレクトリで実行します。

```bash
python -m venv .venv
```

PowerShell:

```powershell
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
$env:PYTHONPATH = (Get-Location).Path
python -m h3.scenario baseline --state-dir .h3-state
python -m h3.scenario improved --state-dir .h3-state
python -m pytest -q
```

macOS / Linux:

```bash
source .venv/bin/activate
python -m pip install -r requirements.txt
export PYTHONPATH="$PWD"
python -m h3.scenario baseline --state-dir .h3-state
python -m h3.scenario improved --state-dir .h3-state
python -m pytest -q
```

`baseline`は4経路に2種類の合成値が残るため`leak_count: 8`、`improved`は`leak_count: 0`なら成功です。これはGuardrails単独の再現ではなく、Guardrailsの適用外になり得る経路を先に可視化する決定的なfixtureです。

## 2. CloudShellで実際のGuardrailsとIAM評価を確認する

CloudShellを開いた直後の`$HOME`へ次の3 fileをuploadします。

- `scripts/run_h3_cloudshell.sh`
- `policy/least-privilege.json`
- このREADME

```bash
mkdir -p "$HOME/aip-c01-h3/scripts" "$HOME/aip-c01-h3/policy"
mv "$HOME/run_h3_cloudshell.sh" "$HOME/aip-c01-h3/scripts/"
mv "$HOME/least-privilege.json" "$HOME/aip-c01-h3/policy/"
mv "$HOME/README.md" "$HOME/aip-c01-h3/"
cd "$HOME/aip-c01-h3"
chmod +x scripts/run_h3_cloudshell.sh
bash scripts/run_h3_cloudshell.sh my-first-run
```

`my-first-run`は`<run-id>`の具体例です。scriptはGuardrail名`aip-c01-h3-my-first-run`とCloudShell作業directory`~/aip-c01-h3-my-first-run`を作ります。再実行時は`second-run`のように別の短い英数字とhyphenを指定してください。fixtureとは合成した検査データ`john@example.com`と`SYNTH-KEY-4821`の組で、実データへ置き換えません。

scriptは次を順に実行します。

1. EMAILを匿名化し、`SYNTH-KEY-####`を独自regexで匿名化するGuardrailを作る
2. Guardrailのversionを作り、`ApplyGuardrail`で合成したモデル出力を検査する
3. exact Guardrail ARNだけに`bedrock:ApplyGuardrail`を許可するpolicyを作業ディレクトリへ生成する
4. IAM Policy Simulatorで対象resourceが`allowed`、別resourceが`implicitDeny`になることを確かめる
5. 終了時にGuardrailを削除し、exact nameを`ListGuardrails`で再確認して残存0をassertする

`result.json`で次を確認します。

- `fixture`: `synthetic-only`
- `guardrail_action`: `GUARDRAIL_INTERVENED`
- `masked_output`: `Contact {EMAIL}. Verification code: {SyntheticKey}.`
- `allowed_resource`: `allowed`
- `other_resource`: `implicitDeny`

この演習では、モデル出力に相当するtextを`source=OUTPUT`で検査します。この結果から、アプリケーションログやツール引数、取得済み参照文書まで自動保護されたとは判断しません。それらは保存前・送信前の最小化、検証、伏せ字化とIAMで別に守ります。

AWS実測のsanitized responseは[`evidence/aws-apply-guardrail-sanitized.json`](evidence/aws-apply-guardrail-sanitized.json)と[`evidence/aws-iam-simulation-sanitized.json`](evidence/aws-iam-simulation-sanitized.json)にあります。account、Guardrail ID、ARN内のaccount/IDだけをplaceholderへ置き換え、判定、検出field、usage、coverageはresponseのまま保存しています。抽出fieldとSHA-256は[`evidence/verification-summary.json`](evidence/verification-summary.json)で照合できます。

## 想定と異なる場合

1. `AccessDeniedException`: 許可された操作とSCP、permission boundary、session policyを確認します。広いAdministrator権限を追加して回避しません。
2. `ValidationException`: Guardrail ID/version、`source=OUTPUT`、content JSON、regexがlookaroundを使っていないことを確認します。
3. `ResourceNotFoundException`: 作成responseのGuardrail IDとRegionが一致するか確認します。
4. IAM評価が想定外: `Resource`が作成したGuardrail ARNと完全一致し、別resourceへwildcardを許可していないか確認します。
5. cleanupで残存: `cleanup.json`のIDを使い、同じRegionで削除します。

## Cleanupと残存確認

scriptは正常終了・途中失敗のどちらでもtrapからGuardrailを削除します。`cleanup.json`が次ならAWS resourceは残っていません。

```json
{"remaining":[]}
```

手動確認:

```bash
aws bedrock list-guardrails --region us-east-1 --no-cli-pager
```

ローカルの演習結果を削除します。

```bash
python -m h3.scenario cleanup --state-dir .h3-state
```

`remaining: []`を確認します。`<run-id>`は実行時に指定した値なので、上の例ではCloudShellの`~/aip-c01-h3-my-first-run`を指します。必要ならこのdirectoryと`.venv`も削除してください。これらはAWS課金resourceではありません。

## 実務へ持ち帰る判断

- Guardrailsの適用地点を明示し、適用外経路を列挙する
- ログには必要最小限だけを残し、保存前に機密値を除く
- 外部ツールへ渡す前と検索結果を利用する前にも検証する
- IAMのResourceを対象Guardrailへ絞り、別resourceへのアクセスが拒否されることを検査する
- retention、監査、例外時の処理を含めて多層防御を継続的に確認する

監査設計、log retention、CloudWatch Logs、KMS key/grantは追加の防御層として検討する項目です。この演習では概念を説明するだけで、作成・実装・AWS実測はしていません。

## 公式情報

- [ApplyGuardrailをアプリケーションフローで使う](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-use-independent-api.html)
- [Sensitive information filters](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-sensitive-filters.html)
- [GuardrailsのIAM permissions](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-permissions.html)
- [Guardrailsの対応Regionとmodel](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-supported.html)
- [IAM Policy Simulator API](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
