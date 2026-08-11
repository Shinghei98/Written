#!/usr/bin/env python3
"""Export every distinct music term for hand-labelling.

    SUPABASE_SECRET_KEY=... python3 tools/export_terms_to_label.py

**Why by hand.** Resolution maps genres and nothing else — 36 concepts — while
741 performers, 174 composers, 288 albums and 1,559 titles are extracted, match
nothing, and leave no trace at all. That is backwards for a product whose
discovery cards carry *"subjects only — artist and channel names, things a
sentence can be about"*. The vocabulary has to come from a real library, and
`EmergentTermMiner` cannot supply it: it needs five distinct users before a term
may become a concept, which is the privacy floor and not a limitation to work
around.

**The output is `ontology-terms.csv` and it is git-ignored.** It is one person's
music library — the same class as `written-distillation-*.csv`, which this repo
already refuses to track.

**Re-running never costs a label.** The script reads any existing CSV first and
carries `concept` and `notes` forward for every term whose text is unchanged, so
a later distillation adds rows rather than resetting the work.

Read from `public.distilled_records`, where Apple's own fields sit unencrypted.
No vault access and no decryption: the vault holds the same strings, and reaching
for them would mean a KMS round trip to read what is already legible here.
"""

from __future__ import annotations

import csv
import json
import os
import sys
import urllib.error
import urllib.request
from collections import Counter

PROJECT_REF = "fwnezkbesjoazlpaflbq"
BASE = f"https://{PROJECT_REF}.supabase.co"
OUTPUT = "ontology-terms.csv"

# Ordered by value per unit of effort rather than alphabetically: genres are
# almost all prefilled and need confirming, composers and performers are the
# subjects the product actually trades on, and titles are the long tail you may
# reasonably never finish.
ROLE_ORDER = ["genre", "composer", "performer", "album", "title"]

FIELDS = ["role", "term", "n", "resolves_today", "concept", "notes"]

PAGE = 1000


def env_key() -> str:
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not key:
        sys.exit(
            "SUPABASE_SECRET_KEY is not set.\n\n"
            "It bypasses row level security entirely, so it lives in your shell "
            "for the length of this run and nowhere else — not in the repo, not "
            "in the app, not in a file."
        )
    return key


def get(path: str, key: str):
    req = urllib.request.Request(f"{BASE}{path}", method="GET")
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read() or b"[]")
    except urllib.error.HTTPError as error:
        sys.exit(f"GET {path} failed: {error.code}\n{error.read().decode()}")


def fetch_records(key: str) -> list[dict]:
    """Every music row, paged.

    PostgREST caps a response, so a single request would silently return the
    first page and the counts would be quietly wrong — the failure mode this
    codebase keeps meeting, where a truncated answer looks exactly like a
    complete one.
    """
    rows: list[dict] = []
    offset = 0
    while True:
        page = get(
            "/rest/v1/distilled_records"
            "?select=name,creator,extra"
            "&source=in.(apple_music,music_library)"
            f"&limit={PAGE}&offset={offset}",
            key,
        )
        rows.extend(page)
        if len(page) < PAGE:
            return rows
        offset += PAGE


def terms(records: list[dict]) -> dict[tuple[str, str], int]:
    """Count every distinct (role, term) pair.

    **The strings are taken exactly as the source wrote them.** No splitting, no
    case folding, no trimming of `&` — because deciding where
    `Berlin Philharmonic & Claudio Abbado` divides is the labelling task, and a
    generator that guessed would be presenting its guess as the data.
    """
    counted: Counter[tuple[str, str]] = Counter()
    for record in records:
        extra = record.get("extra") or {}
        if not isinstance(extra, dict):
            extra = {}

        for role, value in (
            ("title", record.get("name")),
            ("performer", record.get("creator")),
            ("composer", extra.get("composer")),
            ("album", extra.get("album")),
        ):
            text = (value or "").strip()
            if text:
                counted[(role, text)] += 1

        # Genres are the one field the source itself delimits, with a pipe.
        for genre in (extra.get("genres") or "").split("|"):
            text = genre.strip()
            if text:
                counted[("genre", text)] += 1
    return counted


def existing_labels(path: str) -> dict[tuple[str, str], tuple[str, str]]:
    """`(role, term) -> (concept, notes)` from a previous run, if any."""
    if not os.path.exists(path):
        return {}
    # `utf-8-sig` because we write the BOM. Reading with plain `utf-8` leaves it
    # on the first header name, so `role` becomes `﻿role` and every label
    # silently fails to carry forward.
    with open(path, encoding="utf-8-sig", newline="") as handle:
        return {
            (row["role"], row["term"]): (row.get("concept", ""), row.get("notes", ""))
            for row in csv.DictReader(handle)
            if row.get("concept") or row.get("notes")
        }


def seeded_genres() -> dict[str, str]:
    """`normalized label -> concept_key` for the genres already in the ontology.

    **Taken from `tools/seed_music_concepts.py`, not from the database.** That
    file is the source of truth for what was seeded and holds every alias in both
    locales; reading `ontology.concept_labels` back would need the `ontology`
    schema exposed through PostgREST, which it is not, and would tell us the same
    thing one indirection further away.

    Only genres have an answer today. Every other role resolves to nothing, which
    is the reason this file exists.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(os.path.dirname(here), "semantic", "src"))
    sys.path.insert(0, here)
    from seed_music_concepts import GENRES  # noqa: E402
    from written_ontology.normalize import normalize_text  # noqa: E402

    resolved: dict[str, str] = {}
    for concept_key, label, aliases, _broader in GENRES:
        for text in [label, *aliases]:
            resolved[normalize_text(text)] = concept_key
    return resolved


def main() -> None:
    key = env_key()
    records = fetch_records(key)
    counted = terms(records)
    previous = existing_labels(OUTPUT)
    seeded = seeded_genres()
    from written_ontology.normalize import normalize_text

    rows = []
    for role, term in counted:
        concept, notes = previous.get((role, term), ("", ""))
        already = seeded.get(normalize_text(term), "") if role == "genre" else ""
        rows.append({
            "role": role,
            "term": term,
            "n": counted[(role, term)],
            "resolves_today": already,
            # Prefilled with what the ontology already says, so a genre that is
            # right only needs to be left alone. Everything else is blank
            # because nothing resolves it.
            "concept": concept or already,
            "notes": notes,
        })

    # Role by value, then most frequent first inside each role, so stopping part
    # way through leaves the labelled part the part that matters.
    order = {role: index for index, role in enumerate(ROLE_ORDER)}
    rows.sort(key=lambda row: (order.get(row["role"], 99), -row["n"], row["term"]))

    # **UTF-8 with a BOM, and here it is not a formality**: more than a third of
    # these terms are Chinese or Japanese, and without it Excel picks a legacy
    # Western encoding and renders `尼科洛・帕格尼尼` as mojibake. `CSVExporter`
    # does the same for the same reason.
    with open(OUTPUT, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    by_role = Counter(row["role"] for row in rows)
    carried = sum(1 for row in rows if row["concept"] or row["notes"])
    print(f"{OUTPUT}: {len(rows)} terms from {len(records)} rows")
    for role in ROLE_ORDER:
        print(f"  {role:10} {by_role.get(role, 0)}")
    if previous:
        print(f"  carried forward: {carried} labels")


if __name__ == "__main__":
    main()
