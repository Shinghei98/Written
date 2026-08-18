#!/usr/bin/env bash
#
# Stage the pinned weights into S3, checksummed, and never fetched at boot.
#
# **Why not a Hugging Face fetch in the container.** It would put a third party
# in the startup path of a GPU billed by the minute, make the model a moving
# target — a repository can be updated under a tag — and leave no record of what
# was actually loaded. Staged objects are immutable, hashed here, and the hashes
# go into the tokenizer runtime manifest.
#
#   ./aws/serving/stage_weights.sh <local-model-dir> <bucket> <prefix>
#
# The local directory must already hold the files downloaded at the pinned
# revision. This script does not download: separating fetch from stage is what
# lets the fetch be audited before anything immutable is written.

set -euo pipefail

SRC="${1:?local model directory}"
BUCKET="${2:?model bucket}"
PREFIX="${3:?prefix, e.g. qwen3.5-9b/<revision>}"

MANIFEST="$(mktemp)"
: > "$MANIFEST"

# Object lock and versioning belong on the *model* bucket, unlike the async
# bucket: weights are meant to be immutable and are not somebody's text.
while IFS= read -r -d '' file; do
  rel="${file#"$SRC"/}"
  sum="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  printf '%s  %s\n' "$sum" "$rel" >> "$MANIFEST"
  aws s3api put-object \
    --bucket "$BUCKET" --key "$PREFIX/$rel" --body "$file" \
    --server-side-encryption AES256 \
    --checksum-algorithm SHA256 >/dev/null
  echo "staged $rel  $sum"
done < <(find "$SRC" -type f -print0)

aws s3api put-object --bucket "$BUCKET" --key "$PREFIX/SHA256SUMS" \
  --body "$MANIFEST" --server-side-encryption AES256 >/dev/null
echo
echo "manifest s3://$BUCKET/$PREFIX/SHA256SUMS"
sha256sum() { shasum -a 256 "$@"; }
echo "manifest digest $(shasum -a 256 "$MANIFEST" | cut -d' ' -f1)"
