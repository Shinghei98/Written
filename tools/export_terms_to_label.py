#!/usr/bin/env python3
"""Export every distinct music term for hand-labelling.

    SUPABASE_SECRET_KEY=... python3.14 tools/export_terms_to_label.py

Runs on any Python 3.9+. Under Xcode's `python3` it skips the genre prefill and
says so — `written_ontology` needs `enum.StrEnum`, which arrived in 3.11 — and
re-running under a newer interpreter fills those blanks in.

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
import re
import sys
import urllib.error
import urllib.request
from collections import Counter

PROJECT_REF = "fwnezkbesjoazlpaflbq"
BASE = f"https://{PROJECT_REF}.supabase.co"
OUTPUT = "ontology-terms.csv"

# Ordered by value per unit of effort rather than alphabetically, and the order
# is the argument for the whole file: **the terms worth having are the most
# downstream ones** — the specific, nameable things that can appear in somebody
# else's dynamic bio or icebreaker. `LiSA`, `Augustin Hadelich`, `76ers`,
# `bioinformatics` are that; `hub:music` and `sphere:anglophone` are not, which
# is the same line `0108` drew for the Memories page.
#
# `booked_event` leads because a ticketed entry cost money and a Saturday, which
# is the strongest claim any source here returns. Genres are nearly all
# prefilled and need only confirming. Titles are the long tail you may
# reasonably never finish.
ROLE_ORDER = [
    "booked_event",
    "genre",
    "yt_topic",
    "yt_channel",
    "uploader_tag",
    "composer",
    "performer",
    "podcast_show",
    "podcast_publisher",
    "calendar_event",
    "album",
    "title",
]

# **A music library cannot supply the breadth the product needs.** Half of what
# a dynamic bio would want to say — a sport somebody plays, a field they work
# in, a team they follow, a cuisine they book — is never in Apple Music. These
# are the sources that carry it and that this project may derive from:
# `web/en-us/privacy/`'s list minus YouTube, which III.E.4.h forbids deriving
# categories from at all, and minus HealthKit, which is aggregate-only and has
# no workout on any test device.
SOURCES = ["apple_music", "music_library", "apple_podcasts",
           "apple_calendar", "google_calendar", "youtube"]

# **YouTube is here for one reason: it is the only second independence group.**
# `apple_music`, `music_library` and `spotify` all carry `music` by design, so
# no music source can ever be the second witness, and `motif_rules` requires two
# as a check constraint. `0078` measured `creator:le_sserafim` across nine
# separate repost channels — evidence channel-name matching cannot see at all.
#
# **What may be taken from it, and the line is where the label comes from.**
# `snippet.tags` and `brandingSettings.channel.keywords` are written by the
# uploader and returned by the API, so matching a whole one against a controlled
# vocabulary is *reading a supplied label*. That is the determination `0078`
# recorded, and `allow_uploader_tags` has been true since.
#
# **Video titles are deliberately absent.** Producing a label from a title is
# `written_title_tag`, gated behind `allow_title_tags`, which is false — and a
# worksheet of titles for somebody to label is that same operation with a person
# in the loop. It stays out until the §3 amendment is accepted.
#
# `min_tag_length` and whole-tag matching are `0078`'s own resolver parameters,
# repeated here so a term too short to be evidence is never labelled: `creator:yg`
# matched in that measurement, and YG Entertainment is a label, not an artist.
MIN_TAG_LENGTH = 3

# `Ontology.refusedTopics` — `Written/Services/Ontology.swift:729`. A content tag
# is how a protected characteristic arrives without anybody deciding to collect
# it: subscribe to a diocese's channel and a naive mapping writes down your
# religion. Dropped at extraction so a refused topic never reaches a file
# somebody is labelling.
REFUSED_TOPICS = {"Religion", "Politics", "Health", "Military", "Society"}

# **Not drawn, on the same reading rule the dashboard already applies.** A
# birthday or a meeting is collected and synced and simply never *shown*, so a
# worksheet of things to say about somebody is exactly where the rule belongs.
# Matched on the lowercased title, as tokens rather than substrings.
UNDRAWN_TITLE = ("birthday", "meeting", "生日")

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
    # **A shape check, because the server's answer for a mangled key and for a
    # wrong one is the same `401 Invalid API key`.** Omitting the space in
    # `SUPABASE_SECRET_KEY='…'python3.14 tools/…` makes zsh read the whole word
    # as one assignment, so the interpreter's name lands on the end of the key
    # and the script runs anyway via its shebang. That reads as a bad key and
    # sends you to the dashboard to rotate a key that was fine.
    #
    # Never prints the key or any part of it: it is the one thing here that must
    # not reach a terminal, a log or a transcript.
    # A new-style key is base64url — letters, digits, `_` and `-`, and **no
    # dot**. That is what catches the concatenation: `python3.14` brings one.
    # Legacy JWTs are the exception, being three dot-separated segments.
    looks_like_key = (
        re.fullmatch(r"(sb_secret_|sbp_)[A-Za-z0-9_\-]+", key)
        or re.fullmatch(r"eyJ[A-Za-z0-9_\-]*\.[A-Za-z0-9_\-]*\.[A-Za-z0-9_\-]*", key)
    )
    if not looks_like_key:
        sys.exit(
            "SUPABASE_SECRET_KEY does not look like a Supabase key.\n\n"
            "A common cause is a missing space:\n"
            "    SUPABASE_SECRET_KEY='sb_secret_…'python3.14 tools/…   <- wrong\n"
            "    SUPABASE_SECRET_KEY='sb_secret_…' python3.14 tools/…  <- right\n\n"
            "Without the space zsh folds the interpreter's name onto the end of "
            "the key, and the server calls the result invalid."
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
            "?select=source,data_type,name,creator,extra"
            f"&source=in.({','.join(SOURCES)})"
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
        source = record.get("source") or ""
        data_type = record.get("data_type") or ""
        name = (record.get("name") or "").strip()
        creator = (record.get("creator") or "").strip()

        if source in ("apple_podcasts",):
            # A show is the nameable thing — *Acquired*, *Huberman Lab* — and
            # its publisher is a second one. Episodes are not extracted: there
            # is no play history on this source (`playCount` is 0 on episodes
            # demonstrably played), so an episode title is evidence of a
            # download and the show behind it is the interest.
            if data_type == "podcast_show":
                if name:
                    counted[("podcast_show", name)] += 1
                if creator:
                    counted[("podcast_publisher", creator)] += 1
            continue

        if source == "youtube":
            # A channel is the nameable thing on both row kinds: the channel
            # somebody subscribed to, and the channel that uploaded a video they
            # liked. `0078`'s finding was that these are *different* populations
            # — LE SSERAFIM's nine reposters are uploaders and not one of them
            # is subscribed to.
            if data_type == "subscription" and name:
                counted[("yt_channel", name)] += 1
            elif data_type in ("liked_video", "playlist_item") and creator:
                counted[("yt_channel", creator)] += 1

            # Uploader-supplied labels. `tags` come from a liked video's
            # snippet, `keywords` from the channel's branding — the same class
            # one level up, and the half that reaches subscriptions.
            for field in ("tags", "keywords"):
                for tag in (extra.get(field) or "").split("|"):
                    text = tag.strip()
                    if len(text) >= MIN_TAG_LENGTH:
                        counted[("uploader_tag", text)] += 1

            # YouTube's own topics, for confirming coverage only —
            # `tools/youtube_topics.py` owns the provider-topic mapping and a
            # second copy of it here would be two things to keep in step.
            for topic in (extra.get("topics") or "").split("|"):
                text = topic.strip()
                if text and text not in REFUSED_TOPICS:
                    counted[("yt_topic", text)] += 1
            continue

        if source in ("apple_calendar", "google_calendar"):
            # Containers are not terms, and an untyped row is not drawn — the
            # same rule the dashboard applies, and the reason 95 rows on a real
            # device were 88 holidays and 6 real events.
            if data_type != "event" or not name:
                continue
            lowered = name.casefold()
            if any(word in lowered for word in UNDRAWN_TITLE):
                continue
            # **Booked and typed are two different claims and get two roles.**
            # A ticketing site wrote the booked one in by itself, which cost
            # money and a Saturday; the other is what somebody typed for
            # themselves. Both are wanted and the first is worth labelling
            # first, which `ROLE_ORDER` acts on.
            booked = str(extra.get("booked") or "") in ("1", "true", "True")
            counted[("booked_event" if booked else "calendar_event", name)] += 1
            continue

        for role, value in (
            ("title", name),
            ("performer", creator),
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
    try:
        from seed_music_concepts import GENRES  # noqa: E402
        from written_ontology.normalize import normalize_text  # noqa: E402
    except ImportError as error:
        # **A warning, not an exit.** `python3` on macOS is Xcode's 3.9, which
        # has no `enum.StrEnum` and so cannot import `written_ontology` at all.
        # Everything else in this file works there, and the package is reached
        # only to prefill genres that are already correct — so refusing to run
        # would withhold 2,865 rows of labelling work over a convenience for
        # about sixty of them.
        #
        # It is self-healing: re-running under a newer interpreter fills the
        # blanks in, because an empty `concept` is not treated as a label.
        print(
            f"warning: no genre prefill ({error}).\n"
            "         Genres will be blank. For the prefill, re-run with "
            "python3.14 or /opt/homebrew/bin/python3.",
            file=sys.stderr,
        )
        return {}

    resolved: dict[str, str] = {}
    for concept_key, label, aliases, _broader in GENRES:
        for text in [label, *aliases]:
            resolved[normalize_text(text)] = concept_key
    return resolved


def main() -> None:
    # **Before the network, not after.** These two settle in milliseconds and
    # either can end the run; fetching several thousand rows first and then
    # exiting on a missing interpreter wastes a minute and reads like the
    # download was the problem.
    seeded = seeded_genres()
    key = env_key()

    if seeded:
        from written_ontology.normalize import normalize_text
    else:
        # Without the package, compare the strings as they are. Both sides get
        # the same treatment, so the prefill stays consistent; it is simply
        # empty here, since `seeded` is.
        def normalize_text(value):
            return value.casefold().strip()

    records = fetch_records(key)
    counted = terms(records)
    previous = existing_labels(OUTPUT)

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
