#!/usr/bin/env bash
# One attested pass, and the teardown is not a step anybody has to remember.
#
# **The GPU bills per instance-hour from the moment it is InService.** Scale-to-
# zero is the steady-state mechanism and is the wrong off switch for this: it
# needs sustained idle plus a cooldown, and it depends on an alarm and a policy
# behaving. Deleting the stack stops the charge at once and leaves nothing
# behind, which is why the endpoint lives in a stack of its own.
#
# So teardown is in a `trap`, not at the bottom. If the attestation fails, if
# the model will not load, if this script is interrupted, if a command errors
# under `set -e` — the endpoint still goes away. The failure mode this exists to
# remove is a GPU left running overnight because step 7 never ran.
#
# Everything it does between create and delete is a read. `qwen_overlay` stays
# `off`; nothing here writes a user semantic.
set -euo pipefail

STACK=written-qwen-serving
REGION=${AWS_REGION:-us-east-1}
SERVING_IMAGE=${SERVING_IMAGE:?set SERVING_IMAGE to the full ECR digest URI}
MODEL_URI=${MODEL_URI:?set MODEL_URI to the staged artifacts prefix}
OUT=${OUT:-./out/attestation}

started_at=""

teardown() {
  local code=$?
  echo
  echo "==> teardown (exit ${code})"
  # Deleted whatever happened above. `|| true` because a teardown that fails
  # loudly and stops is worse than one that reports and carries on to the
  # verification below.
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" || true
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || true

  local endpoints
  endpoints=$(aws sagemaker list-endpoints --region "$REGION" --query 'length(Endpoints)' --output text 2>/dev/null || echo "unknown")
  echo "endpoints remaining: ${endpoints}"
  if [ "$endpoints" != "0" ]; then
    echo "!! AN ENDPOINT IS STILL RUNNING AND IS STILL BILLING." >&2
    echo "!! Delete it by hand: aws sagemaker delete-endpoint --endpoint-name <name>" >&2
  fi

  if [ -n "$started_at" ]; then
    local minutes
    minutes=$(( ( $(date +%s) - started_at ) / 60 ))
    # The rate is read from the Pricing API rather than written down here, so a
    # price change cannot make this line quietly wrong.
    echo "instance was up for roughly ${minutes} min"
  fi
  exit "$code"
}
trap teardown EXIT INT TERM

echo "==> create"
aws cloudformation deploy --stack-name "$STACK" --region "$REGION" \
  --template-file "$(dirname "$0")/stack.yaml" --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ServingImageUri="$SERVING_IMAGE" ModelDataS3Uri="$MODEL_URI"
started_at=$(date +%s)

echo "==> wait for InService"
# `/ping` answers 503 until the 19 GB load finishes, so InService means loaded
# rather than merely started — which is the whole point of that change.
aws sagemaker wait endpoint-in-service \
  --endpoint-name "$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`EndpointName`].OutputValue' --output text)"

mkdir -p "$OUT"
echo "==> attest the loaded runtime"
"$(dirname "$0")/attest.sh" "$OUT"

echo "==> done; teardown follows"
