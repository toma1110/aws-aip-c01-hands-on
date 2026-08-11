# 低品質RAGを測定して改善する

RAGの回答が期待どおりでないとき、検索と生成を分けて測ります。この演習では同じ4問を使い、filterなしと`document_type=runbook` filterありを比較します。実測では検索順位が改善しても、生成回答に根拠外の「重要」「原因を特定する上で重要」という表現が残りました。検索順位、生成回答、citation、token数、latencyを一続きで保存し、検索が良好でもprompt/生成側に低品質の原因が残ることを確かめます。

## 到達点

- `sample/documents.json`から4つの本文fileと4つのmetadata fileを作れる
- Amazon Bedrock Knowledge BasesとS3 Vectorsでfilterなし/ありを比較できる
- 検索結果をAmazon Nova Microへ渡し、回答とcitationを確認できる
- Recall@2、MRR、answer correctness、faithfulness、token数、latencyで採否を決められる
- 失敗箇所を切り分け、作成したAWS resourceを残さず削除できる

## 前提

- AWS Consoleへサインインできること
- Regionとして`us-east-1`を使用できること
- CloudShellでAWS CLI、Python 3、`jq`を実行できること
- Amazon Titan Text Embeddings V2とAmazon Nova Microをon-demandで利用できること
- S3、S3 Vectors、Bedrock Knowledge Bases、対象prefixのIAM role/policyを作成・参照・削除できること

長期credentialやaccess keyは作成しません。合成データだけを使用し、実際の利用者情報や業務データはuploadしないでください。

## 料金の目安

AWS Price List APIで2026-08-12に確認した価格です。Price Listのeffective dateはすべて2026-08-01です。

- Titan Text Embeddings V2 on-demand input: USD 0.00002 / 1K tokens
- Nova Micro on-demand input: USD 0.000035 / 1K tokens
- Nova Micro on-demand output: USD 0.00014 / 1K tokens
- S3 Vectors Tier 1 / Tier 2: USD 0.055 / 1,000 requests
- S3 Vectors QueryVectors: USD 0.0000025 / request

通常のS3 request/storageも別途発生します。このsample 4文書、8検索、8生成の実行は通常USD 0.01未満ですが、再実行前に現在の価格を確認してください。

## 実行するfile

- `sample/documents.json`: 4つの合成runbook/FAQ
- `sample/queries.json`: 4問、正解document ID、回答に必要な語
- `scripts/run_h1_cloudshell.sh`: 作成、ingestion、検索、生成、評価、cleanupを行うscript
- `scripts/evaluate.py`: 保存済み証跡からmetricを再計算するscript
- `scripts/check_evidence.py`: 証跡の対応関係、cleanup、機密情報混入を検査するscript


## CloudShellで実行する

### 1. Regionと呼び出し元を確認する

AWS Console右上で`米国東部（バージニア北部）`を選び、CloudShellを開きます。terminalで次を実行します。

```bash
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json --no-cli-pager
aws bedrock get-foundation-model \
  --model-identifier amazon.titan-embed-text-v2:0 \
  --region us-east-1 \
  --query 'modelDetails.[modelLifecycle.status,inferenceTypesSupported]' \
  --output json --no-cli-pager
aws bedrock get-foundation-model \
  --model-identifier amazon.nova-micro-v1:0 \
  --region us-east-1 \
  --query 'modelDetails.[modelLifecycle.status,inferenceTypesSupported]' \
  --output json --no-cli-pager
```

両modelが`ACTIVE`で、on-demandまたはinference profileを利用できることを確認します。

### 2. 3 fileをuploadする

CloudShellの`アクション`→`ファイルのアップロード`を使い、次の3 fileをhome directoryへuploadします。

1. `scripts/run_h1_cloudshell.sh`
2. `sample/documents.json`
3. `sample/queries.json`

### 3. scriptを実行する

```bash
chmod +x run_h1_cloudshell.sh
bash run_h1_cloudshell.sh documents.json queries.json
```

第3引数に英数字とhyphenだけのrun IDを指定できます。省略時はUTC時刻を使います。

```bash
bash run_h1_cloudshell.sh documents.json queries.json my-first-run
```

scriptは現在のAWS account IDを`sts:GetCallerIdentity`から取得し、`aip-c01-h1-<run-id>` prefixだけを使用します。同名resourceがある場合は上書きせず停止します。

## scriptが行うAPI処理

1. `documents.json`を4つの`<id>.txt`へ変換する
2. 各本文に対応する`<id>.txt.metadata.json`を作り、`document_id`と`document_type`を入れる
3. source S3 bucketへ本文4件とmetadata 4件をuploadする
4. 1024次元、float32、cosineのS3 vector bucket/indexを作る
5. Titan Text Embeddings V2、source S3、S3 Vectorsだけを許可するservice roleを作る
6. Knowledge BaseとS3 data sourceを作り、ingestionが`COMPLETE`になるまで待つ
7. 同じ4問をfilterなしで`Retrieve`し、上位2件、score、latencyを保存する
8. `document_type=runbook`の`equals` filterを付け、同じ4問を再度`Retrieve`する
9. 各検索結果の本文をNova Microの`Converse`へ渡し、回答末尾に`[document-id]`形式のcitationを出す
10. Converse responseの`usage.inputTokens`、`usage.outputTokens`、`usage.totalTokens`と実測latencyを保存する
11. sample固有のfaithfulness proxyを計算し、manual review欄を`MANUAL_REVIEW_REQUIRED`として保存する
12. metricを計算し、最後に依存順で全resourceを削除する

S3 Vectorsはsemantic searchを使用します。この演習はhybrid searchを扱いません。

## 保存される結果

CloudShellの`~/aip-c01-h1-<run-id>/results/`に次が保存されます。

- `retrieval-results.json`: phase/queryごとのretrieved document ID
- `retrieval.ndjson`: rank、score、retrieval latency
- `generation-details.json`: 回答、citation、retrieved本文、token usage、generation latency、proxy、manual faithfulnessとrationale
- `metrics.json`: Recall@2、MRR、retrieval latency
- `generation-metrics.json`: correctness、faithfulness proxy、manual review status、token合計、generation latency
- `ingestion.json`: ingestion件数
- `cleanup.json`: resourceの最終状態
- `final-evidence.json`: 上記をまとめた実行結果

CloudShellの`アクション`→`ファイルのダウンロード`から必要なfileを取得できます。CloudShell内の`final-evidence.json`は再検査用のraw結果で、run固有のresource prefixを含みます。またmanual faithfulnessは`null`、rationaleは`MANUAL_REVIEW_REQUIRED`です。共有用へ転記するときは、account ID、resource名、絶対path、credentialを除外し、回答・citation・token・latency・cleanup結果は変更しないでください。その後、下記のmanual reviewを行って値とrationaleを確定します。

## metricと採否

- Recall@2: 正解documentが上位2件に含まれる割合
- MRR: 正解documentが1位なら1、2位なら0.5として平均した値
- answer correctness: `queries.json`の`required_terms`が回答にすべて含まれる割合
- faithfulness proxy: citationがretrieved context内にある、`required_terms`がcited本文にある、`unsupported_claims`に登録した既知表現が回答だけに現れない、というsample固有の自動検査
- faithfulness: 回答中のすべての実質的な主張がcited document本文で支持されるかを人が読み、true/falseと短いrationaleを記録した割合
- token数: Converse APIが返す`usage`を合計した実値
- latency: CLI呼び出しの直前からresponse保存直後までの経過時間

filterを採用する条件は次の両方です。

1. improved Recall@2がbaseline Recall@2以上
2. improved MRRがbaseline MRRより厳密に大きい

2026-08-12の確認結果では、Recall@2は1.00→1.00、MRRは0.75→1.00、平均retrieval latencyは1,205.00ms→1,174.75msとなり、filterを採用しました。latencyは環境や時刻で変わるため、採否条件ではなく副作用として併記します。

生成側はbaseline/filter後ともanswer correctness 1.00、manual faithfulness 0.75、sample固有proxy 0.75でした。平均generation latencyは1,438.50ms→1,314.75ms、total tokensは882→915です。q4は必要な`DNS`、`target health`、`timeout`を含むためcorrectnessは合格しましたが、baselineの「重要なステップ」とfilter後の「原因を特定する上で重要」はcited runbookにありません。そのためmanual reviewで両方のfaithfulnessを失敗としました。

この結果から、検索metricが悪い場合はfilter、metadata、chunking、embeddingを先に調べます。今回のq4のように検索metricが良くcitation先も正しいのに根拠外表現がある場合は、Knowledge Baseを作り直す前にprompt、渡したcontext、generation model、出力制約を調べます。検索改善だけで回答改善を断定しません。

## faithfulness proxyとmanual review

`sample/queries.json`の`unsupported_claims`には、今回すでに確認した根拠外表現だけを登録します。たとえばq4には`重要`と`原因を特定`があります。別の表現で同じ主張が生成された場合や、未登録の因果・推奨・程度表現はproxyを通過する可能性があります。したがってproxyを「全実質主張が支持された」という判定には使いません。

再実行後は各generation rowについて次を行います。

1. 回答を一文または一つの実質主張ずつに分ける
2. 各主張を`citation_ids`が指す`retrieved.text`と照合する
3. 全主張が明示的に支持されれば`faithfulness: true`、一つでも根拠外なら`false`にする
4. 根拠外または支持された範囲を`faithfulness_rationale`へ一文で記録する
5. 新しく繰り返し検出したい表現だけを`unsupported_claims`へ追加し、proxyを補助検査として更新する
6. `evaluate.py`でmanual確定値からsummaryを再計算し、`check_evidence.py`でraw/proxy/manualの対応を検査する

未知の根拠外主張はproxyがtrueでもmanual faithfulnessをfalseにできます。proxyとmanual値の相違はエラーではなく、proxyの限界を示す記録です。

## 失敗したときの確認順

### ingestionが失敗する

```bash
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id <KB_ID> \
  --data-source-id <DS_ID> \
  --ingestion-job-id <JOB_ID> \
  --region us-east-1 --no-cli-pager
```

service roleのTitan InvokeModel、source bucket read、S3 Vectors操作権限、1024次元、metadata JSON、data source prefixを確認します。

### filter結果が0件になる

`<id>.txt.metadata.json`が本文と同じS3 prefixにあり、`document_type`の値が`runbook`であることを確認します。ingestionをやり直す前にmetadataのkey/valueとJSON構造を確認してください。

### 生成が失敗する

Nova Microと`us.amazon.nova-micro-v1:0` inference profileが`ACTIVE`か、Converse利用権限があるか、retrieval responseに本文が含まれるかを確認します。検索結果が正常ならKnowledge Baseを作り直さず、generation callだけを切り分けます。

## cleanupと残存確認

scriptは正常終了時も途中失敗時もtrapから次の順で削除します。

1. data source
2. Knowledge Base
3. vector index
4. vector bucket
5. source objectとsource bucket
6. inline policyとservice role

終了時に`H1_RUN_EXIT_CODE`と`cleanup.residual_count`を確認します。`0`以外なら、表示されたrun IDを使って残存を確認します。

```bash
aws bedrock-agent list-knowledge-bases --region us-east-1 --output json --no-cli-pager
aws s3vectors list-vector-buckets --region us-east-1 --output json --no-cli-pager
aws s3api head-bucket --bucket <SOURCE_BUCKET> --region us-east-1
aws iam get-role --role-name <SERVICE_ROLE> --no-cli-pager
```

`not found`または対象prefix 0件になるまで、依存順を崩さず削除してください。CloudTrailなど、この演習が作成していない共通logは削除対象ではありません。


## 公式情報

- https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-vectors-bedrock-kb.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/kb-permissions.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-titan-embed-text.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference-call.html
