# Strands AgentsとMCPに人による承認を追加する

## このハンズオンで解決する課題

エージェントへ自然な言葉で依頼しただけで、外部へ影響するツールが実行される構成には危険があります。このハンズオンでは、合成チケットを更新するローカルツールを使い、次の違いを実際の処理結果で確かめます。

- 読み取りは余計な承認なしで実行する
- 書き込みは実行直前で止め、人が承認または拒否する
- 不正な入力、拒否、時間切れでは何も変更しない
- 同じ依頼を再試行しても書き込みを重複させない

Strands Agentsはモデル、指示、ツール、会話状態を組み合わせるソフトウェア開発キットです。Model Context Protocol（MCP）は、AIアプリケーションと外部ツールを共通の方法で接続します。この演習では、Strands AgentsのMCPクライアントと、標準入出力で動く最小MCPサーバーを実際に接続します。

演習対象は合成チケットです。MCPの標準入出力接続と、Strands AgentsのHumanInTheLoopによる中断・再開は実際のSDKで動かします。一方、ツールを選ぶ部分には結果が毎回同じになる`LocalToolModel`を使います。これは大規模言語モデルではなく、指定されたツールと引数を返す演習用モデルです。このハンズオンは、自然言語の理解や大規模言語モデルによるツール選択の品質を評価するものではありません。

`baseline`、`read`、`approve`、`deny`、`timeout`は、結果を比較しやすくする固定済みの非対話シナリオです。各コマンドは同じ初期チケット（`status: open`、`version: 1`）へリセットしてから始まります。そのため、前のコマンドの結果を次のコマンドへ引き継がず、一つずつ独立した比較として実行できます。

## 安全境界と料金

- AWSアカウント、AWSリージョン、AWSリソース、サービスクォータは使いません。
- Amazon Bedrock AgentCoreも使いません。ローカルだけで承認境界を学べるためです。
- AWS料金は発生しません。必要なのはPythonパッケージを取得する通信だけです。
- 書き込み先は指定した一時ディレクトリ内の合成チケットだけです。本番データ、認証情報、個人情報を入力しないでください。
- 最小権限として、MCPクライアントへ公開するツールを`get_ticket`と`update_ticket_status`に限定し、読み取りだけを承認不要の許可リストへ入れます。

本番用の承認画面、承認待ち状態の永続化、複数利用者の認証・認可、プロンプトインジェクション対策、大規模言語モデルのツール選択精度は対象外です。本番設計では、この演習の入力検証と承認だけで十分とは考えず、これらを別途設計・評価してください。

## 環境

- Python 3.10以上（検証環境: Python 3.13）
- Windows PowerShell、macOS、Linuxのいずれか
- 約200 MBの空き容量

現行の検証済み組み合わせは`strands-agents==1.51.0`、`mcp==1.29.0`です。MCP Python SDK 2.0.0は利用可能ですが、Strands Agents 1.51.0が`mcp>=1.23,<2`を要求するため、この教材では互換範囲の1.29.0を固定しています。

## 準備

このREADMEがあるディレクトリで実行します。

```bash
python -m venv .venv
```

PowerShell:

```powershell
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
$env:PYTHONPATH = (Get-Location).Path
```

macOS / Linux:

```bash
source .venv/bin/activate
python -m pip install -r requirements.txt
export PYTHONPATH="$PWD"
```

## 1. 制御の弱いbaselineを観察する

```bash
python -m h2.scenario baseline --state-dir .h2-state
```

期待結果は、曖昧な`closed-ish`という値でも書き込まれ、チケットの`version`が2になることです。これは問題を再現するためだけの弱いツールです。実システムへ転用しないでください。

合否に使うJSON項目は`agent.stop_reason`が`end_turn`、`agent.interrupt_count`が`0`、`ticket.status`が`closed-ish`、`ticket.version`が`2`です。

## 2. 人による承認を追加する

まず読み取りが承認なしで完了することを確認します。

```bash
python -m h2.scenario read --state-dir .h2-state
```

`interrupt_count: 0`、`status: open`、`version: 1`なら成功です。

次に書き込みを実行します。

```bash
python -m h2.scenario approve --state-dir .h2-state
```

期待結果:

- 最初の処理は`stop_reason: interrupt`で停止する
- 承認後だけ`status: investigating`、`version: 2`になる
- ツール入力は状態の許可リスト、理由、現在のversion、request IDで検証される

合否に使うJSON項目は`before_decision.stop_reason`、`before_decision.interrupt_count`、`ticket.status`、`ticket.version`です。承認後は順に`interrupt`、`1`、`investigating`、`2`になります。

承認は入力検証の代わりではありません。この例では、検証を通った書き込みだけを承認対象にし、更新直前のversionも照合します。

## 3. 拒否と時間切れを確認する

```bash
python -m h2.scenario deny --state-dir .h2-state
python -m h2.scenario timeout --state-dir .h2-state
```

どちらも`status: open`、`version: 1`のままなら成功です。時間切れの例は、承認応答を返さずに処理を終了することで再現します。実サービスでは、承認待ち状態の保存期間と期限切れ処理を別途設計してください。

拒否では`before_decision.stop_reason: interrupt`、`ticket.status: open`、`ticket.version: 1`を確認します。時間切れでは同じ3項目に加えて`decision: timeout-no-resume`を確認します。

## 4. 自動テストを実行する

```bash
python -m pytest -q
```

次を検査します。

- 弱いbaselineで意図しない値が書き込まれる
- 書き込み前に処理が中断され、承認後だけ1回更新される
- 拒否と時間切れでは副作用がない
- 不正な状態値と古いversionは書き込み前に拒否される
- request IDが同じ再試行は重複更新しない
- cleanup後に生成状態が残らない

## 想定と異なる場合

1. `ModuleNotFoundError`なら、仮想環境が有効で、`PYTHONPATH`がこのディレクトリを指すことを確認します。
2. MCPサーバーが開始しない場合は、`python -m h2.mcp_server`を実行し、Pythonと`mcp`のversionを確認します。標準入出力サーバーは待機するため、確認後は`Ctrl+C`で終了します。
3. `H2_STATE_DIR is required`なら、`h2.scenario`経由で実行しているか確認します。
4. 承認後も更新されない場合は、`ticket_id`、`status`、`reason`、`expected_version`、`request_id`の検証条件を確認します。
5. 処理が残っている場合は、実行中のPythonを終了してからcleanupします。ネットワークサービスやAWSリソースは作成していません。

実行時に依存パッケージ由来の警告や、MCPの`Processing request`ログが標準エラーへ表示されることがあります。これは情報表示であり、この演習の合否には使いません。標準出力へ表示されるJSONの上記項目と、コマンドの終了コードで判定してください。

## Cleanupと残存確認

```bash
python -m h2.scenario cleanup --state-dir .h2-state
```

`remaining: []`なら演習データは残っていません。必要なら仮想環境も削除します。

PowerShell:

```powershell
Remove-Item -Recurse -Force .venv, .h2-state -ErrorAction SilentlyContinue
Get-ChildItem -Force .h2-state -ErrorAction SilentlyContinue
```

macOS / Linux:

```bash
rm -rf .venv .h2-state
test ! -e .h2-state && echo "状態ファイルなし"
```

AWSリソース、コンテナ、ログサービス、イメージリポジトリは作成していないため、AWS側のcleanupはありません。

## 実務へ持ち帰る判断

- 手順が固定できるなら、モデルに選択させず決定的なワークフローを優先する
- ツールの入力仕様、許可値、楽観的ロック、冪等性を先に実装する
- 読み取りまで一律承認にせず、副作用とリスクに応じて承認を置く
- 拒否、時間切れ、再試行、監査記録を正常系と同じ重要度で設計する
- MCPは接続方法をそろえるものであり、接続先の権限や安全性を自動的に保証するものではない

## 参照した一次情報

- Strands Agents Python SDK: https://github.com/strands-agents/sdk-python
- Strands Agents Human in the Loop: https://strandsagents.com/docs/user-guide/concepts/agents/interventions/human-in-the-loop/
- Strands Agents MCP client API: https://strandsagents.com/docs/api/python/strands.tools.mcp.mcp_client/
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk
