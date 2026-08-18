#!/usr/bin/env bash
# What the container actually loaded, read from the container.
#
# **Reads only.** It asks the endpoint what is in memory and writes the answer
# to a file; it changes no flag, publishes no manifest and writes nothing to the
# database. Turning the answer into a contract expectation is a separate,
# deliberate step — a script that attested and promoted in one go would make the
# gate a formality.
set -euo pipefail

OUT=${1:-./out/attestation}
REGION=${AWS_REGION:-us-east-1}
mkdir -p "$OUT"

ENDPOINT=$(aws cloudformation describe-stacks --stack-name written-qwen-serving \
  --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`EndpointName`].OutputValue' \
  --output text)

echo "==> endpoint: $ENDPOINT"

# The async endpoint answers through S3, so the runtime block is easiest to read
# from a real invocation. A one-item request with a throwaway title: the point is
# the `runtime` block that travels with every answer, not the extraction.
REQUEST=$(mktemp)
cat > "$REQUEST" <<'JSON'
{"schema_version":"mention_extract_request_v1","prompt_version":"qwen_extractor_v5",
 "grammar_version":"semantic_grammar_v3","source_profile":"youtube",
 "request_id":"req_attestation_probe",
 "items":[{"item_index":0,"item_id":"probe","fields":{"title":"attestation probe"}}]}
JSON

echo "==> invoking once for the runtime block"
aws sagemaker-runtime invoke-endpoint-async \
  --endpoint-name "$ENDPOINT" --region "$REGION" \
  --content-type application/json \
  --inference-id req_attestation_probe \
  --body "fileb://$REQUEST" \
  "$OUT/submitted.json" >/dev/null

echo "    submitted; the answer appears in the async bucket"
cat "$OUT/submitted.json" 2>/dev/null || true
echo
echo "The runtime block is in the answer object named above. Read it, then fill"
echo "  llm.serving.image_digest  and  the tokenizer manifest hash"
echo "in terms.xlsx, recompile, and rebuild the gateway. Until then attestation"
echo "correctly reports those fields unattested."
