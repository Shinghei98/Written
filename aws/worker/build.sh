#!/usr/bin/env bash
#
# Build the worker's deployment zip.
#
# **Wheels for the Lambda's platform, not this laptop's.** `psycopg[binary]` and
# `cryptography` ship compiled extensions, and pip on an arm64 Mac resolves
# arm64 wheels that a Lambda cannot load — it fails at *import* time with a
# missing `.so`, which reads like a packaging typo rather than an architecture
# mismatch. `--platform manylinux2014_x86_64 --only-binary :all:` is what makes
# pip resolve for the target instead of the host.
#
# `boto3` is deliberately absent: the Python runtime bundles it, and shipping a
# copy would pin a version that then drifts from the one AWS patches. Same
# reasoning as `--omit=dev` in the ingestion build.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STAGE="$(mktemp -d)"
OUT="$HERE/dist/worker.zip"

trap 'rm -rf "$STAGE"' EXIT

# **Every `.py` beside this script, not a list of names.** The list was
# `handler.py observations.py`, and adding `fitness.py` built a zip without it —
# no error, a smaller bundle, and the failure deferred to an ImportError on the
# next invocation. A named list is a second place to remember something, and
# this is the project's "verify in the archive, never in the build settings"
# lesson in another language.
cp "$HERE"/*.py "$STAGE/"

# **The music dictionary, from `tools/` rather than a copy here.** It is edited
# by hand — transliterations, works, era exceptions — and two copies would drift
# the moment somebody names an artist in one of them. `music_works` imports
# `music_dictionary` by module name, so both must land flat beside the handler.
cp "$ROOT/tools/music_dictionary.py" "$ROOT/tools/music_works.py" "$STAGE/"

# **`apple_catalog.py` for the same reason, and it is the same argument.** The
# catalogue fetch now runs in the worker as well as by hand, and two copies of
# "how we ask Apple about an ISRC" would drift the first time a query parameter
# changed — `include=artists` was added to it days after the first version and a
# second copy would still be asking without it. `catalogue.py` imports it by
# module name, so it lands flat beside the handler.
#
# It reads its credentials inside functions, never at import, so copying it here
# pulls in no environment requirement the worker does not already declare.
cp "$ROOT/tools/apple_catalog.py" "$STAGE/"
cp "$ROOT/aws/ingestion/supabase-ca.pem" "$STAGE/"

# The vendored package itself — the queue, the worker loop and the job
# contracts. Copied rather than pip-installed from PyPI because it is not
# published anywhere; `semantic/src/written_ontology` is the only copy.
cp -R "$ROOT/semantic/src/written_ontology" "$STAGE/written_ontology"
find "$STAGE/written_ontology" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# **The compiled contract, staged rather than committed into the package.**
# `written_ontology/semantic_contract.py` is the only runtime reader of it and
# looks beside itself first, which is where this puts it — so a deployed Lambda
# never depends on a repository layout it does not have.
#
# Staged, not checked in: the repository keeps exactly one copy, under
# `semantic/contracts/`, and a second committed copy would be precisely the
# duplication the compiler exists to prevent. The bundle gets a copy because a
# bundle must be self-contained; the tree does not.
cp "$ROOT/semantic/contracts/compiled_semantic_contract_v1.json" \
   "$STAGE/written_ontology/compiled_semantic_contract_v1.json"

# **The evaluation corpus travels too, for the same reason the contract does.**
# `evaluation` reads it and nothing else — there is no path from that lane to a
# real account — so a bundle without it turns the fixture-only mode into a mode
# that raises. The layout under `semantic/fixtures/` is preserved because that is
# where `_evaluation_items` looks; flattening it here would mean the reader
# knowing two layouts, which is the defect the gateway image already paid for.
mkdir -p "$STAGE/semantic/fixtures/mention_extract"
cp "$ROOT/semantic/fixtures/mention_extract/"*.json \
   "$STAGE/semantic/fixtures/mention_extract/"

# **`typing_extensions` is named explicitly and that is not belt-and-braces.**
# psycopg 3 requires it on Python before 3.13, and pip's resolver dropped it
# under `--platform`: the first deployed invocation failed with the package's
# own "install the postgres extra" message, which swallows the real ImportError
# and reads like a missing dependency in the wrong place entirely.
python3 -m pip install --quiet --target "$STAGE" \
  --platform manylinux2014_x86_64 --only-binary :all: \
  --implementation cp --python-version 3.12 \
  "psycopg[binary]" cryptography typing_extensions

# **Fail here rather than at invoke.** A missing module in a Lambda zip surfaces
# as a runtime ImportError minutes later, wrapped in whatever the importing
# library chose to say about it. Checking the staged tree costs nothing and
# names the thing that is actually absent.
[ -e "$STAGE/written_ontology/compiled_semantic_contract_v1.json" ] || {
  echo "the compiled semantic contract is missing from the bundle" >&2; exit 1; }

for module in psycopg psycopg_binary cryptography typing_extensions \
              written_ontology music_dictionary music_works; do
  [ -e "$STAGE/$module" ] || [ -e "$STAGE/$module.py" ] || {
    echo "missing from the bundle: $module" >&2; exit 1; }
done

# The glob above, checked rather than assumed. `set -u` makes an unmatched glob
# loud, but a `cp` that silently skipped a file would not be — and this is the
# one that was wrong.
for source in "$HERE"/*.py; do
  [ -e "$STAGE/$(basename "$source")" ] || {
    echo "missing from the bundle: $(basename "$source")" >&2; exit 1; }
done

mkdir -p "$HERE/dist"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" . -x '.*' '*/__pycache__/*' )

# **Hash what actually shipped, not what was on disk before the zip.**
# `release_build_sha256` and `compiled_contract_sha256` are two of the fields
# `ontology.release_manifests` records, and until now nothing produced either —
# the contract declared them required and no step computed one. `aws lambda
# update-function-code` reports `CodeSha256` as base64, so both forms are
# printed and the operator can compare whichever AWS shows them.
contract_sha="$(shasum -a 256 "$ROOT/semantic/contracts/compiled_semantic_contract_v1.json" | cut -d' ' -f1)"
build_sha="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
build_b64="$(openssl dgst -sha256 -binary "$OUT" | base64)"

printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
printf '  release_build_sha256      %s\n' "$build_sha"
printf '  CodeSha256 (base64)       %s\n' "$build_b64"
printf '  compiled_contract_sha256  %s\n' "$contract_sha"
