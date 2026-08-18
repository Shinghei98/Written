#!/usr/bin/env bash
# Does the deployed worker match what the repository says it is?
#
# **A template nothing compares against is a description of an intention.** The
# worker's role, its secrets and its environment were configured by hand and were
# invisible to the repository: nothing could tell whether the deployed function
# could reach the gateway, whether the model-lane credential existed, or whether
# the worker had quietly been given permissions nobody wrote down.
#
# This reads the deployed function and fails on any disagreement. It changes
# nothing — a verifier that repaired what it found would hide the drift it exists
# to report.
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
FUNCTION=${WORKER_FUNCTION:-written-semantic-worker}
GATEWAY=${GATEWAY_FUNCTION:-written-semantic-gateway}
POLICY=${MODEL_LANE_POLICY:-written-worker-model-lane}
SECRET=${MODEL_SECRET_NAME:-written/semantic-model-worker}

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

echo
if [ "$fail" -ne 0 ]; then
  echo "the deployed worker does not match the repository" >&2
  exit 1
fi
echo "the deployed worker matches the repository"
