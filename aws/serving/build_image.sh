#!/usr/bin/env bash
# Build the serving image at a named commit, and wait to be told the digest.
#
# **The commit was an incantation.** `WRITTEN_SOURCE_COMMIT` is not among the
# CodeBuild project's environment variables — it has to be supplied per build,
# because an image that cannot name its source is the defect that job exists to
# remove. Until now it was supplied by hand, which meant the only record of how
# to build this thing lived in somebody's shell history.
#
# **It refuses to build a commit GitHub does not have.** The job fetches
# `serve.py` and `tokenizer_runtime.py` by raw URL at that revision, so a local
# commit that has not been pushed produces a 404 several minutes in, after the
# CUDA base has been pulled. Asking first costs one request.
#
#     ./aws/serving/build_image.sh              # HEAD, once it is pushed
#     ./aws/serving/build_image.sh <commit>
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
PROJECT=${BUILD_PROJECT:-written-build-qwen-serving-image}
COMMIT=${1:-$(git rev-parse HEAD)}
REPO_SLUG=${WRITTEN_REPO_SLUG:-Shinghei98/Written}

echo "==> commit $COMMIT"
for MODULE in serve tokenizer_runtime; do
  url="https://raw.githubusercontent.com/$REPO_SLUG/$COMMIT/aws/serving/$MODULE.py"
  curl -fsSL -o /dev/null "$url" \
    || { echo "GitHub does not serve $MODULE.py at $COMMIT — push first." >&2; exit 1; }
done
echo "    the sources this build reads are on GitHub"

# **The pin is read back from the stack, not typed here.** A second copy of the
# wheel URL would be a second thing to update, and the one that stays stale is
# always the one the build actually uses.
read -r VERSION WHEEL < <(aws cloudformation describe-stacks \
  --stack-name "${BASE_STACK:-written-semantic-model-artifacts}" --region "$REGION" \
  --query "Stacks[0].Parameters[?ParameterKey=='VllmVersion'||ParameterKey=='VllmWheelUrl'].ParameterValue" \
  --output text)
echo "==> engine $VERSION"
echo "    $WHEEL"
[ -n "$VERSION" ] && [ "$VERSION" != "None" ] || {
  echo "the base stack has no VllmVersion; deploy base-stack.yaml with the pin first." >&2
  exit 1; }

BUILD_ID=$(aws codebuild start-build --project-name "$PROJECT" --region "$REGION" \
  --environment-variables-override "name=WRITTEN_SOURCE_COMMIT,value=$COMMIT,type=PLAINTEXT" \
  --query 'build.id' --output text)
echo "==> $BUILD_ID"

# The gates are the deliverable. Tail them rather than reporting only the
# verdict: a refusal names which of six things is wrong, and that is the whole
# value of running them before a GPU exists.
while :; do
  read -r STATUS PHASE < <(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$REGION" \
    --query 'builds[0].[buildStatus,currentPhase]' --output text)
  [ "$STATUS" = "IN_PROGRESS" ] || break
  printf '\r    %s' "$PHASE"
  sleep 15
done
echo
echo "==> $STATUS"

aws logs tail "/aws/codebuild/$PROJECT" --since 1h --region "$REGION" 2>/dev/null \
  | grep -E "wheel verified|cuda compat|engine:|architecture supported|engine argument|structured output|SERVING_IMAGE_DIGEST|\.dkr\.ecr\..*@sha256:" || true

[ "$STATUS" = "SUCCEEDED" ] || exit 1
echo
echo "Pass the digest URI above to one_pass.sh as SERVING_IMAGE."
