#!/usr/bin/env bash
#
# Build the deployment zip.
#
# **Production dependencies only, installed fresh.** The local `node_modules`
# holds the AWS SDK clients as devDependencies so the tests can import the
# handler; shipping them would add several megabytes of code the runtime
# already provides, and — worse — would pin a version that then drifts silently
# from the one AWS patches.
#
# The `--omit=dev` is therefore not an optimisation. It is what keeps the
# deployed SDK the runtime's.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"
OUT="$HERE/dist/ingestion.zip"

trap 'rm -rf "$STAGE"' EXIT

# **Every local module `lib.mjs` imports must be named here.** The file list is
# hand-written, so a new module is bundled only if somebody remembers — and the
# failure is total rather than partial: Lambda resolves the import at load and
# answers `Cannot find module`, so *every* ingestion call fails, not just the
# rows using the new code. `work_titles.mjs` shipped missing exactly once, which
# is why this comment exists.
cp "$HERE/index.mjs" "$HERE/lib.mjs" "$HERE/work_titles.mjs" \
   "$HERE/supabase-ca.pem" "$HERE/package.json" "$STAGE/"
cp "$HERE/package-lock.json" "$STAGE/" 2>/dev/null || true

( cd "$STAGE" && npm ci --omit=dev --silent >/dev/null 2>&1 || npm install --omit=dev --silent >/dev/null 2>&1 )

# The zip must have the handler at its root, not inside a directory — Lambda
# resolves `index.handler` relative to the archive root and reports anything
# else as `Cannot find module 'index'`, which reads like a syntax error.
mkdir -p "$HERE/dist"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" . -x '.*' )

printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
