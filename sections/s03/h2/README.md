# Strands AgentsとMCPで書き込み前の承認を確認する

## このハンズオンで解決する課題

架空のサポートチケットを使い、書き込みを判断が済むまで保留する仕組みを確かめます。読み取りはそのまま実行し、書き込みは許可された場合だけ進めます。この例では、`LocalToolModel`が生成AIモデルの代わりに決められたツールと引数を返すので、実際の人やAIモデルは判断しません。

- 読み取りは余計な承認なしで実行する
- 書き込みは実行直前で止まり、承認された場合だけ進む
- 拒否または時間切れではチケットを変更しない

Strands Agentsは、モデルやツールを組み合わせてエージェントを作るSDKです。MCPはエージェントとツールをつなぐ共通の方式です。この例では、Strands AgentsのMCPクライアントが、PC上で動く小さなMCPサーバーからチケットの読み取り・更新ツールを利用します。

この演習は生成AIモデルを呼び出しません。`LocalToolModel`はStrands SDKのモデル用インターフェースに合わせた演習用実装で、指定済みのツール名と引数を返すだけです。文章を理解したり推論したりしないため、ここで試すのはモデルの判断力ではなく、Strands AgentsのHumanInTheLoopによる中断・再開と、設定済みの応答後に書き込みが進む流れです。

`baseline`、`read`、`approve`、`deny`、`timeout`は、受講者が承認画面で選ぶ対話操作ではありません。シナリオごとにチケットを`status: open`、`version: 1`へ戻し、プログラムが承認・拒否の応答を渡します。`timeout`は実時間を待たず、応答を返さずに処理を再開しないことで表します。データファイルは実行したディレクトリ内の`.h2-state`に作られます。各結果は独立しているため、順番に実行して比較できます。

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

## 1. 承認なしの書き込みを基準として見る

まず、承認制御のない書き込みがどうなるかを確認します。`agent.stop_reason: end_turn`と`agent.interrupt_count: 0`なら、処理が中断されずに終わっています。`ticket.status: closed-ish`、`ticket.version: 2`なら、曖昧な状態値が保存されたことを示します。この結果を次のシナリオと比べます。

```bash
python -m approval_demo.scenario baseline --state-dir .h2-state
```

## 2. 読み取りと承認後の書き込みを比べる

一般にHumanInTheLoopは、書き込みなどの処理を人の判断まで止める仕組みです。このデモでは画面上で人が選ぶのではなく、シナリオが事前に設定した応答をStrands Agentsへ渡します。ここではチケットを読む操作から始めます。`agent.interrupt_count: 0`は承認による中断がなかったこと、`ticket.status: open`と`ticket.version: 1`は読み取りで状態が変わっていないことを示します。

```bash
python -m approval_demo.scenario read --state-dir .h2-state
```

次に書き込みを試します。`approve`シナリオでは、プログラムが承認応答`yes`を渡します。JSONの`before_decision.stop_reason: interrupt`と`before_decision.interrupt_count: 1`で、書き込み前に一度中断したことを確認します。その後の`ticket.status: investigating`と`ticket.version: 2`は、設定済みの承認応答を受けて一度だけ更新されたことを示します。

```bash
python -m approval_demo.scenario approve --state-dir .h2-state
```

この例では、状態値が許可リストにあること、理由が必要な長さであること、チケットのversionが現在値と一致すること、request IDが所定の形式であることを確認します。承認は入力検証の代わりにはなりません。

## 3. 拒否と時間切れを確認する

`deny`シナリオでは、プログラムが拒否応答`no`を渡します。`before_decision.stop_reason: interrupt`で判断待ちに入ったことを確認し、`ticket.status: open`と`ticket.version: 1`が保たれていれば、設定済みの拒否応答後に書き込みが起きていません。

```bash
python -m approval_demo.scenario deny --state-dir .h2-state
```

時間切れシナリオは承認応答を返さず、処理を再開しません。実時間は待ちません。`decision: timeout-no-resume`と`ticket.status: open`、`ticket.version: 1`を見れば、時間切れとして扱い、初期状態から変わらなかったことを確認できます。

```bash
python -m approval_demo.scenario timeout --state-dir .h2-state
```

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
2. MCPサーバーが開始しない場合は、Pythonと`mcp`のversionを確認します。標準入出力サーバーはシナリオから起動します。
3. `H2_STATE_DIR is required`なら、`approval_demo.scenario`経由で実行しているか確認します。
4. 承認後も更新されない場合は、`ticket_id`、`status`、`reason`、`expected_version`、`request_id`の検証条件を確認します。
5. 処理が残っている場合は、実行中のPythonを終了してからcleanupします。ネットワークサービスやAWSリソースは作成していません。

実行時に依存パッケージ由来の警告や、MCPの`Processing request`ログが標準エラーへ表示されることがあります。これは情報表示であり、この演習の合否には使いません。標準出力へ表示されるJSONの上記項目と、コマンドの終了コードで判定してください。

## Cleanupと残存確認

```bash
python -m approval_demo.scenario cleanup --state-dir .h2-state
```

`remaining: []`ならチケットと監査記録のファイルは残っていません。空になった`.h2-state`ディレクトリ自体は残ります。下の削除コマンドで仮想環境と一緒にディレクトリも削除できます。

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
