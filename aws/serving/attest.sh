#!/usr/bin/env bash
# What the container actually loaded, read from the container. **Replaced, not patched.**
#
# The previous version sent the gateway's *request document* straight to the
# endpoint, mistook the `InvokeEndpointAsync` acknowledgement for the answer, and
# never collected the real one — so it left an output object in the bucket and
# reported nothing measured. Three separate mistakes with one symptom: it
# appeared to work.
#
# This builds the provider envelope the serving container actually expects,
# including `response_format.schema`, waits for the answer, **deletes it before
# reading it**, and fails if that delete fails. The retention rule is the same
# one the transport enforces: committing anything derived from provider text we
# cannot show we stopped holding is the trade this refuses.
#
# **Synthetic only.** The probe title is invented here. Nothing about a real
# account, and nothing from Spotify or YouTube, whose terms forbid a model call
# at all.
set -euo pipefail

OUT=${1:-./out/attestation}
REGION=${AWS_REGION:-us-east-1}
STACK=${STACK:-written-qwen-serving}
POLL_TIMEOUT=${POLL_TIMEOUT:-600}

mkdir -p "$OUT"
WORK=$(mktemp -d)
OUTPUT_KEY=""
FAILURE_KEY=""
BUCKET=""

cleanup() {
  local code=$?
  rm -rf "$WORK"
  # **Any object still in the bucket goes, on every exit path.** An abandoned
  # answer is retained provider text — even this one, whose content we wrote —
  # and leaving it would make the lifecycle rule the only thing that removes it.
  if [ -n "$BUCKET" ]; then
    for key in "$OUTPUT_KEY" "$FAILURE_KEY"; do
      [ -n "$key" ] && aws s3api delete-object --bucket "$BUCKET" --key "$key" \
        --region "$REGION" >/dev/null 2>&1 || true
    done
  fi
  exit "$code"
}
trap cleanup EXIT INT TERM

ENDPOINT=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EndpointName`].OutputValue' --output text)
BUCKET=$(aws cloudformation describe-stacks --stack-name written-semantic-gateway \
  --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`AsyncBucketName`].OutputValue' \
  --output text)
echo "==> endpoint $ENDPOINT, async bucket $BUCKET"

# The envelope, built from the compiled contract so the schema sent is the schema
# the gateway would send. A hand-written copy here would be a second definition
# of the request, and the whole apparatus exists to have one.
REQUEST_ID="req_attest_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$WORK/envelope.json" "$REQUEST_ID" "$REPO_ROOT" <<'PY'
import json, pathlib, sys

target, request_id = pathlib.Path(sys.argv[1]), sys.argv[2]
# The repository root, passed in: a script read from stdin has no `__file__`, and
# the previous line silently resolved to the interpreter's idea of nothing.
root = pathlib.Path(sys.argv[3])
contract = json.loads(
    (root / "semantic/contracts/compiled_semantic_contract_v1.json").read_text())
schema = json.loads(
    (root / "semantic/contracts/mention_extract_v2.schema.json").read_text())

envelope = {
    "model": contract["versions"]["model_id"],
    "model_revision": contract["versions"]["model_revision"],
    "temperature": 0,
    "max_output_tokens": contract["output_contract"]["max_output_tokens"],
    "enable_thinking": False,
    "response_format": {"type": "json_schema",
                        "name": "mention_extract_v2",
                        "strict": True,
                        "schema": schema},
    "instructions": contract.get("prompt", {}),
    "input": {
        "schema_version": "mention_extract_request_v1",
        "prompt_version": contract["versions"]["prompt"],
        "grammar_version": contract["versions"]["grammar"],
        # A permitted profile. Never youtube or spotify: their terms forbid a
        # model call on their content at all, probe or not.
        "source_profile": "music_catalog",
        "request_id": request_id,
        # **Invented here.** No account, no library, no provider text.
        "items": [{"item_index": 0, "item_id": "probe",
                   "fields": {"title": "Attestation Probe Sonata"}}],
    },
}
target.write_text(json.dumps(envelope))
print("envelope built")
PY

echo "==> submitting once, inference id $REQUEST_ID"
# One call, inline body, no input object — the same choice the transport makes,
# and for the same reason: a request is somebody's text and the best handling of
# a file is not to create one. `--output json` so the acknowledgement is
# parseable rather than tabular.
aws sagemaker-runtime invoke-endpoint-async \
  --endpoint-name "$ENDPOINT" --region "$REGION" \
  --content-type application/json \
  --inference-id "$REQUEST_ID" \
  --body "fileb://$WORK/envelope.json" \
  --output json \
  "$WORK/discarded.json" > "$WORK/ack.json"

# **The acknowledgement is the JSON returned by the call, not the file.** The
# previous version read the output file the CLI writes and called that the
# answer; that file holds the API response, and the answer lands in S3 later.
OUTPUT_KEY=$(python3 -c "
import json,sys
d=json.load(open('$WORK/ack.json'))
loc=d.get('OutputLocation') or ''
print(loc.split('/',3)[3] if loc.startswith('s3://') else '')")
FAILURE_KEY=$(python3 -c "
import json,sys
d=json.load(open('$WORK/ack.json'))
loc=d.get('FailureLocation') or ''
print(loc.split('/',3)[3] if loc.startswith('s3://') else '')")
echo "    output  s3://$BUCKET/$OUTPUT_KEY"
echo "    failure s3://$BUCKET/$FAILURE_KEY"

echo "==> polling, bounded to ${POLL_TIMEOUT}s"
DEADLINE=$(( $(date +%s) + POLL_TIMEOUT ))
FOUND=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -n "$FAILURE_KEY" ] && aws s3api head-object --bucket "$BUCKET" \
       --key "$FAILURE_KEY" --region "$REGION" >/dev/null 2>&1; then
    FOUND=failure; break
  fi
  if [ -n "$OUTPUT_KEY" ] && aws s3api head-object --bucket "$BUCKET" \
       --key "$OUTPUT_KEY" --region "$REGION" >/dev/null 2>&1; then
    FOUND=output; break
  fi
  sleep 5
done
[ -n "$FOUND" ] || { echo "the endpoint did not answer within ${POLL_TIMEOUT}s" >&2; exit 1; }

KEY=$OUTPUT_KEY; [ "$FOUND" = failure ] && KEY=$FAILURE_KEY
aws s3api get-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" \
  "$WORK/answer.json" >/dev/null

# **Deleted before it is read, and a failed delete stops everything.** Same rule
# the transport applies: an answer we cannot show we stopped holding is one we do
# not get to use.
if ! aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" >/dev/null; then
  echo "could not delete $KEY; refusing to read it" >&2
  exit 1
fi
if [ "$FOUND" = failure ]; then
  echo "the endpoint reported a failure; the object was deleted unread" >&2
  exit 1
fi
OUTPUT_KEY=""; FAILURE_KEY=""   # nothing left for cleanup to remove

echo "==> validating the runtime block"
python3 - "$WORK/answer.json" "$OUT/runtime.json" <<'PY'
import json, pathlib, sys

answer = json.loads(pathlib.Path(sys.argv[1]).read_text())
runtime = answer.get("runtime")
if not isinstance(runtime, dict):
    sys.exit("the answer carried no runtime block; nothing is attested")

required = ("model_id", "model_revision", "tokenizer_runtime_manifest_sha256",
            "serving_image_digest", "vllm", "torch")
missing = [name for name in required if not runtime.get(name)]
if missing:
    sys.exit(f"the runtime block is incomplete: {missing}")

# **No provider text, and none of ours either.** Only identities travel into the
# artifact — a file that quoted the probe would still be a file that quotes a
# model's output, and the habit is the thing worth keeping.
pathlib.Path(sys.argv[2]).write_text(json.dumps(runtime, indent=2, sort_keys=True))
for name in required:
    print(f"  {name:38} {runtime[name]}")
PY

echo
echo "Wrote $OUT/runtime.json — identities only, no text."
echo "Pin the contract from tokenizer_runtime_manifest_sha256 and"
echo "serving_image_digest above, recompile, and rebuild the gateway."
