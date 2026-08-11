#!/usr/bin/env bash
#
# Build the Calendar classifier's deployment zip.
#
# **Far smaller than the worker's, and for a reason worth stating.** This
# function touches no database and decrypts nothing: it takes plaintext calendar
# fields in an invoke payload and returns dispositions. So it needs neither
# `psycopg` nor `cryptography` — the two packages that force the worker's build
# to resolve `manylinux2014_x86_64` wheels — and `boto3` comes from the runtime.
# What is left is the vendored package and one handler, which is pure Python and
# architecture-independent.
#
# That also means it has no Postgres credential and no KMS decrypt permission.
# The most a compromise of it yields is the ability to classify events somebody
# hands it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STAGE="$(mktemp -d)"
OUT="$HERE/dist/classifier.zip"

trap 'rm -rf "$STAGE"' EXIT

# Every `.py` beside this script, not a named list — the worker's build shipped
# a zip missing a new module because the list was one name short, with no error
# and the failure deferred to an ImportError at invoke.
cp "$HERE"/*.py "$STAGE/"

# The vendored package: `written_ontology.calendar_semantics` is the classifier
# §7 permits over Calendar rows, and it is not published anywhere.
cp -R "$ROOT/semantic/src/written_ontology" "$STAGE/written_ontology"
find "$STAGE/written_ontology" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

for module in written_ontology; do
  [ -e "$STAGE/$module" ] || { echo "missing from the bundle: $module" >&2; exit 1; }
done
for source in "$HERE"/*.py; do
  [ -e "$STAGE/$(basename "$source")" ] || {
    echo "missing from the bundle: $(basename "$source")" >&2; exit 1; }
done

# Fail at build rather than at invoke: the handler imports several names out of
# the package, and a rename upstream would otherwise surface as a cold-start
# ImportError on the path ingestion depends on.
PYTHONPATH="$STAGE" python3 - <<'PY'
import importlib
for name in (
    "written_ontology.calendar_semantics",
    "written_ontology.export_adapter",
):
    importlib.import_module(name)
from written_ontology.calendar_semantics import CalendarClassifier, CalendarDisposition
from written_ontology.export_adapter import (
    _OFFLINE_CALENDAR_CARRIERS, _OFFLINE_CALENDAR_PLACE_CATALOG,
    _OFFLINE_CALENDAR_PLACE_LABELS, _OFFLINE_LEISURE_VENDORS,
)
PY

mkdir -p "$HERE/dist"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" . -x '.*' '*/__pycache__/*' )

printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
