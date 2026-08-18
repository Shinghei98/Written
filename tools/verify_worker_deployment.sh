#!/usr/bin/env bash
# Does the deployed worker match what the repository says it is?
#
# **A template nothing compares against is a description of an intention.** The
# worker's role, its secrets and its environment were configured by hand and were
# invisible to the repository: nothing could tell whether the deployed function
# could reach the gateway, whether the model-lane credential existed, or whether
# the worker had quietly been given permissions nobody wrote down.
#
# This reads the deployed function and fails on any disagreement. It **repairs**
# nothing — a verifier that fixed what it found would hide the drift it exists to
# report — but it is no longer purely passive: the last section invokes the
# worker with a probe payload, because the one thing that cannot be read from
# outside is whether the model-lane credential actually reaches the database as
# `semantic_model_worker`. That probe reads the catalogue and rolls back; it
# claims no job, calls no gateway and records no invocation.
#
# **Existence was never the question.** Before the probe, every check here was
# equally true while `semantic_model_worker` could not log in at all — the secret
# existed, held a value, and named an identity with no way to use it. That is the
# state the lane shipped in, and nothing reported it.
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
FUNCTION=${WORKER_FUNCTION:-written-semantic-worker}
GATEWAY=${GATEWAY_FUNCTION:-written-semantic-gateway}
POLICY=${MODEL_LANE_POLICY:-written-worker-model-lane}
SECRET=${MODEL_SECRET_NAME:-written/semantic-model-worker}
STACK=${MODEL_LANE_STACK:-written-semantic-model-lane}

fail=0
note() { printf '  %-52s %s\n' "$1" "$2"; }
bad()  { printf '  %-52s %s\n' "$1" "$2"; fail=1; }

echo "==> $FUNCTION"
config=$(aws lambda get-function-configuration --function-name "$FUNCTION" \
  --region "$REGION" --output json)

role_arn=$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Role"])')
role_name=${role_arn##*/}
note "execution role" "$role_name"

# --- the environment the code actually reads -------------------------------
#
# Named here rather than derived, because the point is to notice when the code
# starts reading something the deployment does not set. A variable added to
# `model_lane.py` and forgotten here fails the *next* run of this script, which
# is the earliest anything could.
for key in DB_SECRET_ID VAULT_KEY_ARN WRITTEN_GATEWAY_FUNCTION WRITTEN_MODEL_DB_SECRET_ID; do
  value=$(printf '%s' "$config" | python3 -c "
import json,sys
env = json.load(sys.stdin).get('Environment', {}).get('Variables', {})
print(env.get('$key', ''))")
  if [ -z "$value" ]; then
    bad "env $key" "UNSET — the model lane cannot run without it"
  else
    note "env $key" "$value"
  fi
done

# --- the credential the model lane needs -----------------------------------
if aws secretsmanager describe-secret --secret-id "$SECRET" --region "$REGION" \
     >/dev/null 2>&1; then
  note "secret $SECRET" "exists"
  # **Existence is not a value.** A secret created by the template and never
  # filled in reads as configured and fails at first use, which is the failure
  # this whole script exists to move earlier.
  if aws secretsmanager get-secret-value --secret-id "$SECRET" --region "$REGION" \
       --query SecretString --output text >/dev/null 2>&1; then
    note "  its value" "set"
  else
    bad "  its value" "EMPTY — created by IaC, never filled in"
  fi
else
  bad "secret $SECRET" "MISSING — deploy aws/worker/stack.yaml"
fi

# --- the grants ------------------------------------------------------------
if aws iam list-attached-role-policies --role-name "$role_name" \
     --query "AttachedPolicies[?PolicyName=='$POLICY'].PolicyName" --output text \
     2>/dev/null | grep -q "$POLICY"; then
  note "policy $POLICY" "attached"
else
  bad "policy $POLICY" "NOT ATTACHED — the worker cannot invoke the gateway"
fi

# --- and the thing it is all for -------------------------------------------
if aws lambda get-function --function-name "$GATEWAY" --region "$REGION" \
     >/dev/null 2>&1; then
  note "gateway $GATEWAY" "exists"
else
  bad "gateway $GATEWAY" "MISSING"
fi

# --- the stack, and the one thing its outputs can vouch for -----------------
#
# **`aws/worker/stack.yaml` owns neither the Lambda, its role, nor its
# environment**, deliberately — a stack that can delete the worker is a worse
# risk than one that cannot describe it. So it has exactly two outputs, and only
# one of them has a counterpart in the function's environment. Comparing the
# rest against CloudFormation would be a claim the outputs cannot support, so
# this compares the one and says so.
secret_arn=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ModelWorkerSecretArn'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$secret_arn" ] || [ "$secret_arn" = "None" ]; then
  bad "stack $STACK" "NOT DEPLOYED — aws cloudformation deploy aws/worker/stack.yaml"
else
  note "stack $STACK" "deployed"
  configured=$(printf '%s' "$config" | python3 -c "
import json,sys
env = json.load(sys.stdin).get('Environment', {}).get('Variables', {})
print(env.get('WRITTEN_MODEL_DB_SECRET_ID', ''))")
  # The function may name the secret by ARN or by name; both resolve, and a
  # verifier that insisted on one spelling would fail a working deployment.
  case "$secret_arn" in
    *"$configured"*) note "  its secret is the one the lane reads" "$configured" ;;
    *) if [ "$configured" = "$SECRET" ]; then
         note "  its secret is the one the lane reads" "$configured (by name)"
       else
         bad "  its secret is the one the lane reads" \
             "the lane reads '$configured', the stack made '$secret_arn'"
       fi ;;
  esac
fi

# --- and the only check of a credential that means anything -----------------
#
# **Using it.** Everything above is readable from outside and none of it can
# tell whether the password lands on the right identity: a pooler authenticates
# a username and assumes a role behind it, so a connection succeeding says
# nothing about *whose* grants are in force. The probe asks `current_user`.
echo
echo "==> the model lane, asked to prove itself"
probe_out=$(mktemp)
trap 'rm -f "$probe_out"' EXIT
if aws lambda invoke --function-name "$FUNCTION" --region "$REGION" \
     --payload '{"probe":"model_lane"}' --cli-binary-format raw-in-base64-out \
     "$probe_out" >/dev/null 2>&1; then
  python3 - "$probe_out" <<'READ' || fail=1
import json, sys

body = json.loads(open(sys.argv[1]).read() or "{}")
# A Lambda that raised answers with errorMessage rather than our shape. Say so
# as a failure rather than reporting nothing, which reads as a pass.
if "checks" not in body:
    print("  %-52s %s" % ("the probe did not run", body.get("errorType", body)))
    raise SystemExit(1)
for check in body["checks"]:
    print("  %-52s %s" % (check["check"],
                          ("ok" if check["ok"] else "FAILED") + " — " + check["detail"]))
raise SystemExit(0 if body.get("ok") else 1)
READ
else
  bad "the probe" "could not invoke $FUNCTION"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "the deployed worker does not match the repository" >&2
  exit 1
fi
echo "the deployed worker matches the repository, and the model lane connects"
