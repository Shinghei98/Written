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
cp "$ROOT/aws/ingestion/supabase-ca.pem" "$STAGE/"

# The vendored package itself — the queue, the worker loop and the job
# contracts. Copied rather than pip-installed from PyPI because it is not
# published anywhere; `semantic/src/written_ontology` is the only copy.
cp -R "$ROOT/semantic/src/written_ontology" "$STAGE/written_ontology"
find "$STAGE/written_ontology" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

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

printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
