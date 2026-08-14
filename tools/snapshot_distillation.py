#!/usr/bin/env python3
"""Keep a copy of somebody's distillation, so they never have to send it twice.

**Why this exists.** Four times in two days a projection or weighting change has
been paid for by asking a person to open the app and distil again — `title_works`
for YouTube, `place_key` for Calendar three times over, and Spotify's `top_track`
weight still owed. Worse, on 2026-08-14 Timi distilled twice and **neither
attempt reached the server on any path**: zero ingestion-Lambda invocations, and
her newest `distilled_records` row still stamped the previous afternoon. Asking
again is not a plan when asking is what is broken.

The rows themselves are already safe: `public.distilled_records` is append-only
and holds every record her device ever sent. This writes them to a file so a
later re-projection can be replayed from disk rather than from a phone.

    export SUPABASE_SECRET_KEY=sb_secret_...

    python3 tools/snapshot_distillation.py --user <uuid>
    python3 tools/snapshot_distillation.py --user <uuid> --source spotify
    python3 tools/snapshot_distillation.py --user <uuid> --full

**The output is personal data and goes in `out/`, which is git-ignored** — the
same rule the CSV exports follow, and for the same reason: a distillation must
never enter history. The file holds one person's library, calendar and viewing;
treat it as you would the export.

**`summary_distilled_records` by default, the base table with `--full`.** The
summary view returns the deduped latest row per `(user, source, data_type,
item_id)`, which is what a replay wants — `tools/calendar_review.py` learned that
the hard way and reported nine promotions against the vault's five by counting
history instead of state. `--full` takes the base table when you want the history
itself rather than the current picture.

The key bypasses row level security completely. It lives in your shell for the
length of this run and nowhere else. See CLAUDE.md: never commit `sb_secret_…`.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timezone

BASE = "https://fwnezkbesjoazlpaflbq.supabase.co"

# PostgREST caps a page; a real library runs to thousands of rows, so this pages
# rather than asking for everything and silently receiving the first thousand —
# which is the shape of bug that makes a snapshot quietly incomplete.
PAGE = 1000


def env_key() -> str:
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not key:
        sys.exit(
            "SUPABASE_SECRET_KEY is not set.\n\n"
            "It bypasses row level security entirely, so it lives in your shell "
            "for the length of this run and nowhere else — not in the repo, not "
            "in a file, and not pasted into a chat: every key this project has "
            "lost went through a transcript.\n\n"
            "    export SUPABASE_SECRET_KEY=sb_secret_...\n"
        )
    return key


def fetch(key: str, table: str, user_id: str, source: str | None) -> list[dict]:
    rows: list[dict] = []
    offset = 0
    while True:
        query = {
            "user_id": f"eq.{user_id}",
            "select": "*",
            "order": "source.asc,data_type.asc,item_id.asc",
            "limit": str(PAGE),
            "offset": str(offset),
        }
        if source:
            query["source"] = f"eq.{source}"
        url = f"{BASE}/rest/v1/{table}?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(url, headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(request) as response:
                page = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")[:400]
            sys.exit(f"{table} read failed: HTTP {error.code}\n{body}")
        rows.extend(page)
        # A short page is the last page. Asking again would be one wasted round
        # trip per snapshot and an easy off-by-one when a library is an exact
        # multiple of the page size.
        if len(page) < PAGE:
            return rows
        offset += PAGE


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Snapshot one person's distilled records to a local file.")
    # **Required and explicit.** A snapshot tool with a default user is a tool
    # that eventually writes somebody's library to disk by accident.
    parser.add_argument("--user", required=True, help="the account's uuid")
    parser.add_argument("--source", help="one source, or every source if omitted")
    parser.add_argument("--full", action="store_true",
                        help="the append-only base table rather than the summary view")
    parser.add_argument("--out", default="out/replay",
                        help="directory for the snapshot (git-ignored by default)")
    args = parser.parse_args()

    key = env_key()
    table = "distilled_records" if args.full else "summary_distilled_records"
    rows = fetch(key, table, args.user, args.source)
    if not rows:
        sys.exit(f"no rows in {table} for {args.user[:8]}… — nothing to keep")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = f"-{args.source}" if args.source else ""
    directory = pathlib.Path(args.out)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{args.user}{suffix}-{stamp}.json"

    payload = {
        "user_id": args.user,
        "table": table,
        "source": args.source,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "row_count": len(rows),
        "records": rows,
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False))

    by_source = Counter(row.get("source", "?") for row in rows)
    print(f"kept {len(rows)} rows from {table} → {path}")
    for source, count in sorted(by_source.items(), key=lambda pair: -pair[1]):
        print(f"  {count:6d}  {source}")
    print(
        "\nThis file is one person's library, calendar and viewing. `out/` is "
        "git-ignored; keep it that way."
    )


if __name__ == "__main__":
    main()
