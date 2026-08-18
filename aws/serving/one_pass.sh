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

# **The cap is money, and the enforcement is time.** AWS has no hard dollar stop:
# Budgets cannot terminate a SageMaker endpoint, and its cost data lags hours
# behind usage, so a $10 budget fires long after $10 has been spent on something
# billing by the hour. What *can* be enforced exactly is the only thing that
# spends the money, and the minutes are derived from the live price rather than
# from a number written here — a rate change cannot make this quietly wrong.
BUDGET_USD=${BUDGET_USD:-5}
INSTANCE=${INSTANCE:-ml.g6e.xlarge}
SERVING_IMAGE=${SERVING_IMAGE:?set SERVING_IMAGE to the full ECR digest URI}
# **Digest-pinned or refused.** The stack derives the container's declared digest
# by splitting this on `@`, so a tag-pinned URI would give it an empty string and
# the gateway would then refuse every answer for a runtime mismatch it could not
# explain. Failing here says why.
case "$SERVING_IMAGE" in
  *@sha256:*) : ;;
  *) echo "SERVING_IMAGE must be pinned by digest (…@sha256:…), got: $SERVING_IMAGE" >&2
     exit 1 ;;
esac
MODEL_URI=${MODEL_URI:?set MODEL_URI to the staged artifacts prefix}
OUT=${OUT:-./out/attestation}

started_at=""
watchdog_pid=""
schedule_name=""

hourly_rate() {
  aws pricing get-products --region us-east-1 --service-code AmazonSageMaker \
    --filters "Type=TERM_MATCH,Field=instanceName,Value=${INSTANCE}" \
              'Type=TERM_MATCH,Field=component,Value=Hosting' \
    --max-results 30 --output json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for raw in d.get('PriceList', []):
    p = json.loads(raw)
    if 'US East (N. Virginia)' not in p['product']['attributes'].get('location', ''):
        continue
    for term in p['terms']['OnDemand'].values():
        for dim in term['priceDimensions'].values():
            print(dim['pricePerUnit']['USD']); raise SystemExit
raise SystemExit('no hosting price found')
"
}

gateway_endpoint() {
  # **A controlled gateway update, not an import.** Every other parameter is
  # carried forward with `UsePreviousValue`, so this changes exactly one thing
  # and cannot silently reset the image the gateway is running to a default.
  local name="$1"
  local params=(ParameterKey=SagemakerEndpointName,ParameterValue="$name")
  local key
  for key in ImageUri GatewayImageDigest ServingImageDigest TokenizerSha256 \
             ModelId ModelRevision WorkerRoleArn; do
    params+=("ParameterKey=${key},UsePreviousValue=true")
  done
  # **A failure here stops the pass.** Swallowing it meant the endpoint came up,
  # the gateway stayed pointed at nothing, and the attestation failed for a
  # reason that read like a broken model. The one tolerated non-zero is "no
  # updates are to be performed", which is success spelled as an error.
  local out
  if ! out=$(aws cloudformation update-stack --stack-name written-semantic-gateway \
       --region "$REGION" --use-previous-template \
       --capabilities CAPABILITY_NAMED_IAM \
       --parameters "${params[@]}" 2>&1); then
    case "$out" in
      *"No updates are to be performed"*) return 0 ;;
      *) echo "gateway update failed: $out" >&2; return 1 ;;
    esac
  fi
  aws cloudformation wait stack-update-complete \
    --stack-name written-semantic-gateway --region "$REGION"
}

teardown() {
  local code=$?
  echo
  echo "==> teardown (exit ${code})"
  [ -n "$watchdog_pid" ] && kill "$watchdog_pid" 2>/dev/null || true

  # **Unwired before the endpoint is deleted.** A gateway pointing at an endpoint
  # that no longer exists would answer `provider_error` for a reason that reads
  # like an outage, and its IAM statement would name a resource that is gone.
  echo "==> clearing the gateway's endpoint"
  # Reported, not fatal: teardown must continue to the endpoint delete whatever
  # this does, because leaving the GPU running is the worse outcome.
  gateway_endpoint "" || echo "!! the gateway still names a deleted endpoint" >&2
  # The armed deadline is removed only once the endpoint is actually gone, which
  # the check below verifies. Removing it first would drop the backstop at the
  # exact moment the teardown might be failing.
  
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

  if [ "$endpoints" = "0" ] && [ -n "$schedule_name" ]; then
    aws scheduler delete-schedule --name "$schedule_name" --region "$REGION" 2>/dev/null || true
  elif [ -n "$schedule_name" ]; then
    echo "   deadline schedule ${schedule_name} left armed deliberately" >&2
  fi

  if [ -n "$started_at" ]; then
    local minutes
    minutes=$(( ( $(date +%s) - started_at ) / 60 ))
    # The rate is read from the Pricing API rather than written down here, so a
    # price change cannot make this line quietly wrong.
    echo "instance was up for roughly ${minutes} min"
    python3 -c "
rate = ${RATE:-0} or 0
print(f'estimated charge: \${{ {minutes} / 60 * rate :.2f}}')" 2>/dev/null || true
  fi
  exit "$code"
}
trap teardown EXIT INT TERM

echo "==> create"
aws cloudformation deploy --stack-name "$STACK" --region "$REGION" \
  --template-file "$(dirname "$0")/stack.yaml" --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ServingImageUri="$SERVING_IMAGE" ModelDataS3Uri="$MODEL_URI"
started_at=$(date +%s)

RATE=$(hourly_rate)
MINUTES=$(python3 -c "print(max(5, int(float('$BUDGET_USD') / float('$RATE') * 60)))")
echo "==> budget \$${BUDGET_USD} at \$${RATE}/hr  ->  hard stop after ${MINUTES} min"

ENDPOINT_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EndpointName`].OutputValue' --output text)

# **Switch one: on AWS, and it survives this machine.** A trap does not run when
# the laptop sleeps, the network drops or the process is SIGKILLed — which are
# exactly the cases that leave a GPU running. This does not depend on anything
# here still being alive.
schedule_name="written-qwen-deadline-$(date +%s)"
DEADLINE=$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc)
       + datetime.timedelta(minutes=${MINUTES})).strftime('%Y-%m-%dT%H:%M:%S'))")
aws scheduler create-schedule --name "$schedule_name" --region "$REGION" \
  --schedule-expression "at(${DEADLINE})" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target "{\"Arn\":\"arn:aws:scheduler:::aws-sdk:sagemaker:deleteEndpoint\",
             \"RoleArn\":\"arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/written-qwen-teardown\",
             \"Input\":\"{\\\"EndpointName\\\":\\\"${ENDPOINT_NAME}\\\"}\"}" \
  --action-after-completion DELETE >/dev/null
echo "    deadline armed on AWS at ${DEADLINE}Z (schedule ${schedule_name})"

# **Switch two: here, and it is the fast one.** The scheduler is the backstop
# against this machine disappearing; this is what stops the charge promptly when
# the pass simply runs long.
( sleep $(( MINUTES * 60 ))
  echo "!! budget deadline reached; deleting the endpoint" >&2
  aws sagemaker delete-endpoint --endpoint-name "$ENDPOINT_NAME" --region "$REGION" || true
) &
watchdog_pid=$!

echo "==> wait for InService"
# `/ping` answers 503 until the 19 GB load finishes, so InService means loaded
# rather than merely started — which is the whole point of that change.
aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT_NAME"

echo "==> wiring the gateway to the endpoint"
gateway_endpoint "$ENDPOINT_NAME" || {
  echo "the gateway could not be pointed at $ENDPOINT_NAME; refusing to attest "\
       "against a gateway that is not connected" >&2
  exit 1
}

mkdir -p "$OUT"
echo "==> attest the loaded runtime"
"$(dirname "$0")/attest.sh" "$OUT"

echo "==> done; teardown follows"
