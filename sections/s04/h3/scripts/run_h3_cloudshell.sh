#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
RUN_ID="${1:-$(date -u +%Y%m%d%H%M%S)}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9-]+$ ]] || { echo "run-idは英数字とhyphenだけで指定してください" >&2; exit 2; }
NAME="aip-c01-h3-${RUN_ID}"
WORK_DIR="$HOME/${NAME}"
GUARDRAIL_ID=""
mkdir -p "$WORK_DIR"

cleanup() {
  if [[ -n "$GUARDRAIL_ID" ]]; then
    aws bedrock delete-guardrail --guardrail-identifier "$GUARDRAIL_ID" --region "$REGION" --no-cli-pager || true
  fi
  local remaining="[]"
  for _ in {1..30}; do
    remaining="$(aws bedrock list-guardrails --region "$REGION" --output json --no-cli-pager \
      | jq --arg name "$NAME" '[.guardrails[] | select(.name == $name) | {id, name}]')"
    [[ "$remaining" == "[]" ]] && break
    sleep 1
  done
  jq -n --arg name "$NAME" --argjson remaining "$remaining" \
    '{checked_exact_name:$name,remaining:$remaining}' | tee "$WORK_DIR/cleanup.json"
  jq -e '.remaining | length == 0' "$WORK_DIR/cleanup.json" >/dev/null
}
trap cleanup EXIT

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --no-cli-pager)"
cat >"$WORK_DIR/sensitive-policy.json" <<'JSON'
{
  "piiEntitiesConfig": [{"type":"EMAIL","action":"ANONYMIZE"}],
  "regexesConfig": [{"name":"SyntheticKey","description":"Synthetic training identifier","pattern":"SYNTH-KEY-[0-9]{4}","action":"ANONYMIZE"}]
}
JSON

CREATE_JSON="$(aws bedrock create-guardrail \
  --name "$NAME" \
  --description "AIP-C01 synthetic data hands-on; safe to delete" \
  --blocked-input-messaging "Input blocked" \
  --blocked-outputs-messaging "Output blocked" \
  --sensitive-information-policy-config "file://$WORK_DIR/sensitive-policy.json" \
  --region "$REGION" --output json --no-cli-pager)"
GUARDRAIL_ID="$(jq -r .guardrailId <<<"$CREATE_JSON")"

cat >"$WORK_DIR/content.json" <<'JSON'
[{"text":{"text":"Contact john@example.com. Verification code: SYNTH-KEY-4821."}}]
JSON
VERSION="$(aws bedrock create-guardrail-version \
  --guardrail-identifier "$GUARDRAIL_ID" \
  --description "H3 transient verification" \
  --region "$REGION" --query version --output text --no-cli-pager)"
for _ in {1..30}; do
  STATUS="$(aws bedrock get-guardrail --guardrail-identifier "$GUARDRAIL_ID" \
    --guardrail-version "$VERSION" --region "$REGION" --query status --output text --no-cli-pager)"
  [[ "$STATUS" == "READY" ]] && break
  sleep 1
done
[[ "$STATUS" == "READY" ]]
aws bedrock-runtime apply-guardrail \
  --guardrail-identifier "$GUARDRAIL_ID" --guardrail-version "$VERSION" \
  --source OUTPUT --content "file://$WORK_DIR/content.json" \
  --region "$REGION" --output json --no-cli-pager >"$WORK_DIR/apply-guardrail.json"
jq -e '.action == "GUARDRAIL_INTERVENED" and .outputs[0].text == "Contact {EMAIL}. Verification code: {SyntheticKey}."' \
  "$WORK_DIR/apply-guardrail.json" >/dev/null

sed -e "s/111122223333/$ACCOUNT_ID/g" -e "s/HANDSON_GUARDRAIL_ID/$GUARDRAIL_ID/g" \
  policy/least-privilege.json >"$WORK_DIR/policy.json"
GUARDRAIL_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:guardrail/${GUARDRAIL_ID}"
OTHER_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:guardrail/other-guardrail"
aws iam simulate-custom-policy --policy-input-list "file://$WORK_DIR/policy.json" \
  --action-names bedrock:ApplyGuardrail --resource-arns "$GUARDRAIL_ARN" \
  --output json --no-cli-pager >"$WORK_DIR/iam-allowed.json"
aws iam simulate-custom-policy --policy-input-list "file://$WORK_DIR/policy.json" \
  --action-names bedrock:ApplyGuardrail --resource-arns "$OTHER_ARN" \
  --output json --no-cli-pager >"$WORK_DIR/iam-denied.json"
jq -e '.EvaluationResults[0].EvalDecision == "allowed"' "$WORK_DIR/iam-allowed.json" >/dev/null
jq -e '.EvaluationResults[0].EvalDecision == "implicitDeny"' "$WORK_DIR/iam-denied.json" >/dev/null

jq -n \
  --arg action "$(jq -r .action "$WORK_DIR/apply-guardrail.json")" \
  --arg output "$(jq -r '.outputs[0].text' "$WORK_DIR/apply-guardrail.json")" \
  --arg allow "$(jq -r '.EvaluationResults[0].EvalDecision' "$WORK_DIR/iam-allowed.json")" \
  --arg deny "$(jq -r '.EvaluationResults[0].EvalDecision' "$WORK_DIR/iam-denied.json")" \
  '{fixture:"synthetic-only",guardrail_action:$action,masked_output:$output,allowed_resource:$allow,other_resource:$deny}' \
  | tee "$WORK_DIR/result.json"
