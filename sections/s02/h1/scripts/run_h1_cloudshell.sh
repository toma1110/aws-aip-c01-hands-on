#!/usr/bin/env bash
set -Eeuo pipefail

REGION="us-east-1"
DOCUMENTS_JSON="${1:-documents.json}"
QUERIES_JSON="${2:-queries.json}"
RUN_ID="${3:-$(date -u +%Y%m%d-%H%M%S)}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager)
PREFIX="aip-c01-h1-${RUN_ID}"
SRC_BUCKET="${PREFIX}-${ACCOUNT_ID}-src"
VECTOR_BUCKET="${PREFIX}-vectors"
INDEX_NAME="${PREFIX}-index"
ROLE_NAME="${PREFIX}-kb-role"
POLICY_NAME="${PREFIX}-kb-access"
KB_NAME="${PREFIX}-kb"
DS_NAME="${PREFIX}-ds"
MODEL_ID="amazon.titan-embed-text-v2:0"
GEN_MODEL_ID="us.amazon.nova-micro-v1:0"
WORKDIR="$HOME/${PREFIX}"

mkdir -p "$WORKDIR/documents" "$WORKDIR/results"
export AWS_PAGER=""

KB_ID=""
DS_ID=""
INGESTION_JOB_ID=""
INDEX_ARN=""
SRC_CREATED=0
VECTOR_BUCKET_CREATED=0
INDEX_CREATED=0
ROLE_CREATED=0
KB_CREATED=0
DS_CREATED=0
CLEANUP_DONE=0

run_json() {
  aws "$@" --region "$REGION" --output json --no-cli-pager
}

wait_kb_status() {
  local expected="$1"
  local status=""
  for _ in $(seq 1 60); do
    status=$(run_json bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" 2>/dev/null | jq -r '.knowledgeBase.status // empty') || true
    if [[ "$status" == "$expected" ]]; then
      return 0
    fi
    if [[ "$status" == "FAILED" ]]; then
      run_json bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" || true
      return 1
    fi
    sleep 5
  done
  return 1
}

wait_ingestion() {
  local status=""
  for _ in $(seq 1 90); do
    status=$(run_json bedrock-agent get-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --ingestion-job-id "$INGESTION_JOB_ID" | jq -r '.ingestionJob.status')
    if [[ "$status" == "COMPLETE" ]]; then
      run_json bedrock-agent get-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --ingestion-job-id "$INGESTION_JOB_ID" > "$WORKDIR/results/ingestion.json"
      return 0
    fi
    if [[ "$status" == "FAILED" || "$status" == "STOPPED" ]]; then
      run_json bedrock-agent get-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --ingestion-job-id "$INGESTION_JOB_ID" > "$WORKDIR/results/ingestion-failed.json" || true
      return 1
    fi
    sleep 5
  done
  return 1
}

cleanup() {
  set +e

  if [[ "$DS_CREATED" == "1" && -n "$KB_ID" && -n "$DS_ID" ]]; then
    run_json bedrock-agent delete-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" >/dev/null 2>&1
    for _ in $(seq 1 30); do
      run_json bedrock-agent get-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" >/dev/null 2>&1 || break
      sleep 3
    done
  fi

  if [[ "$KB_CREATED" == "1" && -n "$KB_ID" ]]; then
    run_json bedrock-agent delete-knowledge-base --knowledge-base-id "$KB_ID" >/dev/null 2>&1
    for _ in $(seq 1 40); do
      run_json bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" >/dev/null 2>&1 || break
      sleep 3
    done
  fi

  if [[ "$INDEX_CREATED" == "1" ]]; then
    for _ in $(seq 1 20); do
      run_json s3vectors delete-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$INDEX_NAME" >/dev/null 2>&1 && break
      sleep 3
    done
  fi

  if [[ "$VECTOR_BUCKET_CREATED" == "1" ]]; then
    for _ in $(seq 1 20); do
      run_json s3vectors delete-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" >/dev/null 2>&1 && break
      sleep 3
    done
  fi

  if [[ "$SRC_CREATED" == "1" ]]; then
    aws s3 rm "s3://${SRC_BUCKET}/" --recursive --region "$REGION" --no-cli-pager >/dev/null 2>&1
    run_json s3api delete-bucket --bucket "$SRC_BUCKET" >/dev/null 2>&1
  fi

  if [[ "$ROLE_CREATED" == "1" ]]; then
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" --no-cli-pager >/dev/null 2>&1
    aws iam delete-role --role-name "$ROLE_NAME" --no-cli-pager >/dev/null 2>&1
  fi

  local residual=0
  local checks='[]'
  if run_json bedrock-agent list-knowledge-bases --max-results 100 | jq -e --arg n "$KB_NAME" '.knowledgeBaseSummaries[]? | select(.name==$n)' >/dev/null; then
    residual=$((residual + 1))
    checks=$(jq -c '. + [{"resource":"knowledge-base","state":"residual"}]' <<<"$checks")
  else
    checks=$(jq -c '. + [{"resource":"knowledge-base","state":"absent"}]' <<<"$checks")
  fi
  if run_json s3vectors get-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" >/dev/null 2>&1; then
    residual=$((residual + 1))
    checks=$(jq -c '. + [{"resource":"vector-bucket","state":"residual"}]' <<<"$checks")
  else
    checks=$(jq -c '. + [{"resource":"vector-bucket","state":"absent"}]' <<<"$checks")
  fi
  if run_json s3api head-bucket --bucket "$SRC_BUCKET" >/dev/null 2>&1; then
    residual=$((residual + 1))
    checks=$(jq -c '. + [{"resource":"source-bucket","state":"residual"}]' <<<"$checks")
  else
    checks=$(jq -c '. + [{"resource":"source-bucket","state":"absent"}]' <<<"$checks")
  fi
  if aws iam get-role --role-name "$ROLE_NAME" --no-cli-pager >/dev/null 2>&1; then
    residual=$((residual + 1))
    checks=$(jq -c '. + [{"resource":"service-role","state":"residual"}]' <<<"$checks")
  else
    checks=$(jq -c '. + [{"resource":"service-role","state":"absent"}]' <<<"$checks")
  fi

  jq -n \
    --argjson attempted true \
    --argjson residual_count "$residual" \
    --argjson checks "$checks" \
    '{attempted:$attempted,residual_count:$residual_count,checks:$checks}' \
    > "$WORKDIR/results/cleanup.json"

  if [[ "$residual" == "0" ]]; then
    CLEANUP_DONE=1
  fi
  set -e
}

on_exit() {
  local rc=$?
  if [[ "$CLEANUP_DONE" != "1" ]]; then
    cleanup
  fi
  echo "H1_RUN_EXIT_CODE=${rc}"
  if [[ -f "$WORKDIR/results/final-evidence.json" ]]; then
    jq -c . "$WORKDIR/results/final-evidence.json"
  elif [[ -f "$WORKDIR/results/cleanup.json" ]]; then
    jq -c '{status:"failed-before-evidence",cleanup:.}' "$WORKDIR/results/cleanup.json"
  fi
  exit "$rc"
}

trap on_exit EXIT

command -v aws >/dev/null
command -v jq >/dev/null
command -v python3 >/dev/null
[[ -f "$DOCUMENTS_JSON" ]]
[[ -f "$QUERIES_JSON" ]]
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]
[[ "$RUN_ID" =~ ^[a-zA-Z0-9-]{1,24}$ ]]

python3 - "$DOCUMENTS_JSON" "$WORKDIR/documents" <<'PY'
import json
import re
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
output = Path(sys.argv[2])
if len(source) != 4:
    raise SystemExit("documents.json must contain exactly 4 documents")
for item in source:
    document_id = item["id"]
    if not re.fullmatch(r"[a-z0-9-]+", document_id):
        raise SystemExit(f"invalid document id: {document_id}")
    (output / f"{document_id}.txt").write_text(f'{item["title"]}\n{item["text"]}\n', encoding="utf-8")
    metadata = {"metadataAttributes":{"document_id":document_id,"document_type":item["document_type"]}}
    (output / f"{document_id}.txt.metadata.json").write_text(json.dumps(metadata, ensure_ascii=False) + "\n", encoding="utf-8")
PY

cat > "$WORKDIR/trust.json" <<JSON
{
  "Version":"2012-10-17",
  "Statement":[{
    "Effect":"Allow",
    "Principal":{"Service":"bedrock.amazonaws.com"},
    "Action":"sts:AssumeRole",
    "Condition":{
      "StringEquals":{"aws:SourceAccount":"${ACCOUNT_ID}"},
      "ArnLike":{"aws:SourceArn":"arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:knowledge-base/*"}
    }
  }]
}
JSON

cat > "$WORKDIR/policy.json" <<JSON
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"FoundationModel",
      "Effect":"Allow",
      "Action":["bedrock:InvokeModel"],
      "Resource":["arn:aws:bedrock:${REGION}::foundation-model/${MODEL_ID}"]
    },
    {
      "Sid":"SourceBucketList",
      "Effect":"Allow",
      "Action":["s3:ListBucket"],
      "Resource":["arn:aws:s3:::${SRC_BUCKET}"]
    },
    {
      "Sid":"SourceObjectRead",
      "Effect":"Allow",
      "Action":["s3:GetObject"],
      "Resource":["arn:aws:s3:::${SRC_BUCKET}/documents/*"]
    },
    {
      "Sid":"S3Vectors",
      "Effect":"Allow",
      "Action":[
        "s3vectors:GetIndex",
        "s3vectors:PutVectors",
        "s3vectors:GetVectors",
        "s3vectors:ListVectors",
        "s3vectors:DeleteVectors",
        "s3vectors:QueryVectors"
      ],
      "Resource":[
        "arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}",
        "arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}/index/*"
      ]
    }
  ]
}
JSON

run_json s3api create-bucket --bucket "$SRC_BUCKET" > "$WORKDIR/results/source-bucket-create.json"
SRC_CREATED=1
aws s3 cp "$WORKDIR/documents/" "s3://${SRC_BUCKET}/documents/" --recursive --region "$REGION" --no-cli-pager > "$WORKDIR/results/source-upload.txt"

run_json s3vectors create-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" > "$WORKDIR/results/vector-bucket-create.json"
VECTOR_BUCKET_CREATED=1
run_json s3vectors create-index \
  --vector-bucket-name "$VECTOR_BUCKET" \
  --index-name "$INDEX_NAME" \
  --dimension 1024 \
  --distance-metric cosine \
  --data-type float32 \
  --metadata-configuration '{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_METADATA","AMAZON_BEDROCK_TEXT"]}' \
  > "$WORKDIR/results/index-create.json"
INDEX_CREATED=1
INDEX_ARN=$(jq -r '.indexArn' "$WORKDIR/results/index-create.json")

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://$WORKDIR/trust.json" \
  --output json --no-cli-pager > "$WORKDIR/results/role-create.json"
ROLE_CREATED=1
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$WORKDIR/policy.json" \
  --no-cli-pager
ROLE_ARN=$(jq -r '.Role.Arn' "$WORKDIR/results/role-create.json")
sleep 10

run_json bedrock-agent create-knowledge-base \
  --name "$KB_NAME" \
  --role-arn "$ROLE_ARN" \
  --knowledge-base-configuration "{\"type\":\"VECTOR\",\"vectorKnowledgeBaseConfiguration\":{\"embeddingModelArn\":\"arn:aws:bedrock:${REGION}::foundation-model/${MODEL_ID}\",\"embeddingModelConfiguration\":{\"bedrockEmbeddingModelConfiguration\":{\"dimensions\":1024,\"embeddingDataType\":\"FLOAT32\"}}}}" \
  --storage-configuration "{\"type\":\"S3_VECTORS\",\"s3VectorsConfiguration\":{\"indexArn\":\"${INDEX_ARN}\"}}" \
  > "$WORKDIR/results/kb-create.json"
KB_CREATED=1
KB_ID=$(jq -r '.knowledgeBase.knowledgeBaseId' "$WORKDIR/results/kb-create.json")
wait_kb_status ACTIVE

run_json bedrock-agent create-data-source \
  --knowledge-base-id "$KB_ID" \
  --name "$DS_NAME" \
  --data-deletion-policy DELETE \
  --data-source-configuration "{\"type\":\"S3\",\"s3Configuration\":{\"bucketArn\":\"arn:aws:s3:::${SRC_BUCKET}\",\"inclusionPrefixes\":[\"documents/\"]}}" \
  --vector-ingestion-configuration '{"chunkingConfiguration":{"chunkingStrategy":"NONE"}}' \
  > "$WORKDIR/results/ds-create.json"
DS_CREATED=1
DS_ID=$(jq -r '.dataSource.dataSourceId' "$WORKDIR/results/ds-create.json")

run_json bedrock-agent start-ingestion-job \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$DS_ID" \
  > "$WORKDIR/results/ingestion-start.json"
INGESTION_JOB_ID=$(jq -r '.ingestionJob.ingestionJobId' "$WORKDIR/results/ingestion-start.json")
wait_ingestion

jq -r '.[] | [.id,.text,.relevant_ids[0],(.required_terms|join("|")),(.unsupported_claims|join("|"))] | @tsv' "$QUERIES_JSON" > "$WORKDIR/queries.tsv"
[[ "$(wc -l < "$WORKDIR/queries.tsv")" -eq 4 ]]

: > "$WORKDIR/results/retrieval.ndjson"
while IFS=$'\t' read -r query_id query_text relevant_id required_terms unsupported_claims; do
  for phase in baseline improved; do
    config='{"vectorSearchConfiguration":{"numberOfResults":2}}'
    if [[ "$phase" == "improved" ]]; then
      config='{"vectorSearchConfiguration":{"numberOfResults":2,"filter":{"equals":{"key":"document_type","value":"runbook"}}}}'
    fi
    start_ms=$(date +%s%3N)
    run_json bedrock-agent-runtime retrieve \
      --knowledge-base-id "$KB_ID" \
      --retrieval-query "{\"text\":\"${query_text}\"}" \
      --retrieval-configuration "$config" \
      > "$WORKDIR/results/${phase}-${query_id}.json"
    end_ms=$(date +%s%3N)
    latency_ms=$((end_ms-start_ms))
    jq -c \
      --arg phase "$phase" \
      --arg query_id "$query_id" \
      --arg relevant_id "$relevant_id" \
      --argjson latency_ms "$latency_ms" \
      '{phase:$phase,query_id:$query_id,relevant_id:$relevant_id,latency_ms:$latency_ms,retrieved:[.retrievalResults[]|{document_id:(.metadata.document_id // (.location.s3Location.uri|split("/")[-1]|sub("\\.txt$";""))),score:.score}]}' \
      "$WORKDIR/results/${phase}-${query_id}.json" >> "$WORKDIR/results/retrieval.ndjson"
  done
done < "$WORKDIR/queries.tsv"

: > "$WORKDIR/results/generation.ndjson"
while IFS=$'\t' read -r query_id query_text relevant_id required_terms unsupported_claims; do
  for phase in baseline improved; do
    retrieval_file="$WORKDIR/results/${phase}-${query_id}.json"
    context=$(jq -r '.retrievalResults[] | "[\(.metadata.document_id)] \(.content.text)"' "$retrieval_file")
    messages=$(jq -nc --arg question "$query_text" --arg context "$context" '[{"role":"user","content":[{"text":("質問: " + $question + "\n\n検索結果:\n" + $context)}]}]')
    start_ms=$(date +%s%3N)
    run_json bedrock-runtime converse \
      --model-id "$GEN_MODEL_ID" \
      --messages "$messages" \
      --system '[{"text":"検索結果だけを根拠に日本語で簡潔に回答してください。手順は検索結果の表記どおりすべて書き、回答末尾に根拠document IDを角括弧で示してください。例: [runbook-auth]。検索結果にない内容は補わないでください。"}]' \
      --inference-config '{"maxTokens":160,"temperature":0,"topP":0.9}' \
      > "$WORKDIR/results/${phase}-${query_id}-generation.json"
    end_ms=$(date +%s%3N)
    latency_ms=$((end_ms-start_ms))
    jq -c \
      --arg phase "$phase" \
      --arg query_id "$query_id" \
      --arg relevant_id "$relevant_id" \
      --arg required_terms "$required_terms" \
      --arg unsupported_claims "$unsupported_claims" \
      --argjson latency_ms "$latency_ms" \
      --slurpfile retrieval "$retrieval_file" \
      '{phase:$phase,query_id:$query_id,relevant_id:$relevant_id,required_terms:($required_terms|split("|")),unsupported_claims:(if $unsupported_claims=="" then [] else ($unsupported_claims|split("|")) end),latency_ms:$latency_ms,answer:.output.message.content[0].text,usage:.usage,retrieved:[$retrieval[0].retrievalResults[]|{document_id:.metadata.document_id,text:.content.text}]}' \
      "$WORKDIR/results/${phase}-${query_id}-generation.json" >> "$WORKDIR/results/generation.ndjson"
  done
done < "$WORKDIR/queries.tsv"

python3 - "$WORKDIR/results/generation.ndjson" "$WORKDIR/results/generation-details.json" "$WORKDIR/results/generation-metrics.json" <<'PY'
import json
import re
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
for row in rows:
    answer_lower = row["answer"].lower()
    unsupported = [claim.lower() for claim in row.get("unsupported_claims", [])]
    row["citation_ids"] = re.findall(r"\[([a-z0-9-]+)\]", row["answer"])
    row["answer_correctness"] = all(term.lower() in answer_lower for term in row["required_terms"])
    retrieved = {item["document_id"]: item["text"].lower() for item in row["retrieved"]}
    cited_text = "\n".join(retrieved[citation] for citation in row["citation_ids"] if citation in retrieved)
    row["faithfulness_proxy"] = bool(row["citation_ids"]) and all(citation in retrieved for citation in row["citation_ids"]) and all(term.lower() in cited_text for term in row["required_terms"]) and not any(claim in answer_lower and claim not in cited_text for claim in unsupported)
    row["faithfulness"] = None
    row["faithfulness_rationale"] = "MANUAL_REVIEW_REQUIRED"

def metric(phase):
    selected = [row for row in rows if row["phase"] == phase]
    return {
        "answer_correctness": sum(row["answer_correctness"] for row in selected) / len(selected),
        "faithfulness_proxy": sum(row["faithfulness_proxy"] for row in selected) / len(selected),
        "faithfulness": None,
        "manual_review_status": "required",
        "latency_ms_average": sum(row["latency_ms"] for row in selected) / len(selected),
        "input_tokens_total": sum(row["usage"]["inputTokens"] for row in selected),
        "output_tokens_total": sum(row["usage"]["outputTokens"] for row in selected),
        "total_tokens": sum(row["usage"]["totalTokens"] for row in selected),
        "query_count": len(selected),
    }

Path(sys.argv[2]).write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
Path(sys.argv[3]).write_text(json.dumps({"baseline":metric("baseline"),"improved":metric("improved")}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

jq -s '{baseline:[.[]|select(.phase=="baseline")|{query_id,retrieved_ids:[.retrieved[].document_id]}],improved:[.[]|select(.phase=="improved")|{query_id,retrieved_ids:[.retrieved[].document_id]}]}' \
  "$WORKDIR/results/retrieval.ndjson" > "$WORKDIR/results/retrieval-results.json"

python3 - "$WORKDIR/results/retrieval.ndjson" "$WORKDIR/results/metrics.json" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]

def score(phase):
    selected = [row for row in rows if row["phase"] == phase]
    recalls = []
    reciprocal_ranks = []
    latencies = []
    for row in selected:
        ids = [item["document_id"] for item in row["retrieved"][:2]]
        relevant = row["relevant_id"]
        recalls.append(1.0 if relevant in ids else 0.0)
        reciprocal_ranks.append(0.0 if relevant not in ids else 1.0 / (ids.index(relevant) + 1))
        latencies.append(row["latency_ms"])
    return {
        "recall_at_2": sum(recalls) / len(recalls),
        "mrr": sum(reciprocal_ranks) / len(reciprocal_ranks),
        "latency_ms_average": sum(latencies) / len(latencies),
        "query_count": len(selected),
    }

baseline = score("baseline")
improved = score("improved")
decision = "adopt" if improved["recall_at_2"] >= baseline["recall_at_2"] and improved["mrr"] > baseline["mrr"] else "hold"
Path(sys.argv[2]).write_text(json.dumps({"baseline": baseline, "improved": improved, "decision": decision}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

cleanup

jq -n \
  --arg status "completed" \
  --arg region "$REGION" \
  --arg model_id "$MODEL_ID" \
  --arg resource_prefix "$PREFIX" \
  --slurpfile ingestion "$WORKDIR/results/ingestion.json" \
  --slurpfile metrics "$WORKDIR/results/metrics.json" \
  --slurpfile retrieval "$WORKDIR/results/retrieval-results.json" \
  --slurpfile detail "$WORKDIR/results/retrieval.ndjson" \
  --slurpfile generation "$WORKDIR/results/generation-details.json" \
  --slurpfile generation_metrics "$WORKDIR/results/generation-metrics.json" \
  --slurpfile cleanup "$WORKDIR/results/cleanup.json" \
  '{status:$status,region:$region,embedding_model_id:$model_id,generation_model_id:"us.amazon.nova-micro-v1:0",resource_prefix:$resource_prefix,ingestion:$ingestion[0].ingestionJob.statistics,metrics:$metrics[0],retrieval_results:$retrieval[0],retrieval_detail:$detail,generation_detail:$generation[0],generation_metrics:$generation_metrics[0],cleanup:$cleanup[0]}' \
  > "$WORKDIR/results/final-evidence.json"

if [[ "$(jq -r '.cleanup.residual_count' "$WORKDIR/results/final-evidence.json")" != "0" ]]; then
  exit 2
fi

trap - EXIT
echo "H1_RUN_EXIT_CODE=0"
jq -c . "$WORKDIR/results/final-evidence.json"
