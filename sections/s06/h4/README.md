# EvaluationからRegression Gateを作る

## この演習でできるようになること

生成AIの変更を平均値だけで承認すると、少数でも重大な失敗を見逃します。この演習では、版を固定した合成golden datasetを使い、品質・遅延・コストを比較しながら、重大ケース、警告、人手確認を別々に扱うRegression Gateを作ります。

- **golden dataset**: 期待する結果と重要度をあらかじめ決め、変更前後を同じ条件で比べる問題集です。
- **fixture**: 演習を何度実行しても同じ結果になる、合成した入力・採点値の一式です。
- **Regression Gate**: 以前できたことを変更後も満たすか検査し、公開を進めるか止めるか決める関門です。

実モデルやAWS APIは呼びません。評価値は学習用の決定的なfixtureで、モデル品質を実測した結果ではありません。production prompt、実在人物の情報、credential、secretを入力しないでください。

## Gateの判断

- **hard gate**: 重大ケースの品質が閾値未満、いずれかの必須検査が失敗、または人手確認が却下・不明なら、平均値が改善しても`ROLLBACK`します。
- **warning**: 遅延またはコストの増加を表示しますが、それだけではrollbackしません。
- **manual review**: 自動採点だけで決めないケースが未承認なら`HOLD`します。
- すべてを満たしたときだけ`PASS`、warningだけなら`PASS_WITH_WARNINGS`です。

`datasets/golden-v1.json`と`configs/gate-v1.json`を同じcommitでversion管理する想定です。評価対象を変えたときはdataset versionを上げ、旧版との比較可能性を保ちます。

## 実行環境

- Python 3.11以降
- AWS account、network、追加packageは不要

このREADMEのディレクトリで実行します。

PowerShell:

```powershell
$env:PYTHONPATH = (Get-Location).Path
python -m h4.cli baseline
python -m h4.cli average-pass-critical-fail
python -m h4.cli warning-only
python -m h4.cli manual-review
python -m h4.cli fixed
python -m h4.cli cleanup
python -m unittest discover -s tests -v
```

macOS / Linux:

```bash
export PYTHONPATH="$PWD"
python -m h4.cli baseline
python -m h4.cli average-pass-critical-fail
python -m h4.cli warning-only
python -m h4.cli manual-review
python -m h4.cli fixed
python -m h4.cli cleanup
python -m unittest discover -s tests -v
```

各scenarioは毎回同じ初期fixtureから独立して計算します。前の実行結果は次の判定へ影響しません。

実行結果は専用directoryの`.h4-state/<scenario>.json`へ保存されます。CIで判定根拠を追跡するartifactを模したもので、`decision`だけでなくhard failure、warning、人手確認待ちを確認します。`cleanup`はこの専用directoryだけを削除し、`remaining: []`なら演習結果は残っていません。root、親directory、専用directory外、symlinkを`--output-dir`へ指定すると拒否します。

## 確認するJSON field

| scenario | `decision` | 確認点 |
| --- | --- | --- |
| `baseline` | `PASS` | 現行版が基準を満たす |
| `average-pass-critical-fail` | `ROLLBACK` | `average_quality_improved: true`でも`hard_failures`に重大ケースが入る |
| `warning-only` | `PASS_WITH_WARNINGS` | `warnings`に遅延・コスト増加が入り、hard failureはない |
| `manual-review` | `HOLD` | `manual_review_pending`が残る |
| `fixed` | `PASS` | 修正版にhard failure、warning、未確認がない |
| `cleanup` | — | `remaining: []` |

CIではCLIの終了コードを主体にします。`PASS`と`PASS_WITH_WARNINGS`は0、`ROLLBACK`と`HOLD`は2なので、deploy jobを自動的に止められます。JSONは人が理由を確認する証跡で、`decision`だけを目視してCIを進めるものではありません。`hard_failures`、`warnings`、`manual_review_pending`をartifactとして保存し、rollback対象の変更versionとdataset/config versionを一緒に記録します。

## 21分の活動

1. **予測（3分）**: `average-pass-critical-fail`の平均値だけを見たら公開できるか、重大ケースを別判定すべきか予測します。
2. **閾値確認（4分）**: `configs/gate-v1.json`の重大品質閾値、遅延・コストwarning閾値を読みます。
3. **実出力（6分）**: baselineと5 scenarioを実行し、終了コードと`.h4-state/<scenario>.json`を比べます。
4. **判断（5分）**: 平均改善なのにrollbackした理由、warningだけなら進める理由、manual reviewで止まる理由をJSON fieldから説明します。
5. **cleanup（3分）**: `cleanup`を実行し、`remaining: []`と`.h4-state`不存在を確認します。

## 想定と異なる場合

- `dataset_version mismatch`: datasetとconfigを同じ版へ戻します。都合よく閾値を下げません。
- 平均値が同じなのに結果が違う: `critical`と`required_check_passed`を確認します。
- 遅延・コストだけ悪化した: warningの根拠を確認し、許容するなら人間が変更理由を記録します。
- 人手確認が残る: reviewerが対象caseを確認し、fixtureの`manual_review_status`を`approved`または`rejected`として新しいversionに記録します。

## AWSとの関係

Amazon Bedrockにはautomatic model evaluation jobがあり、built-inまたはcustom prompt dataset、IAM service role、Amazon S3などを使う構成があります。この演習の目的はCIの分岐とrollbackを再現することなので、AWS jobやmodel inferenceを作成・実行しません。AWS resource、quota消費、AWS料金は0です。実運用でmanaged evaluationへ置き換える場合も、重大ケースを平均へ埋めず、このGateへ同じ判定契約で入力してください。

- [Amazon Bedrock automatic model evaluation](https://docs.aws.amazon.com/bedrock/latest/userguide/evaluation-automatic.html)
- [Supported Regions and models](https://docs.aws.amazon.com/bedrock/latest/userguide/evaluation-support.html)
- [Amazon Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)
