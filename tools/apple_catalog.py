#!/usr/bin/env python3
"""Look Spotify's ISRCs up in Apple's catalogue, and emit the answers as SQL.

**Why this exists.** Measured 2026-08-14 on a 593-row Spotify library: 1,522
terms extracted, 6 accepted mappings, 0 eligible assertions. Apple Music stamps
a genre on every song row — 641 of 641 library songs, 455 of 455 playlist items
— and Spotify stamps one on none, because Spotify's API states no genre at
track level at all. A genre is the root of everything a person can see:
`sphere:*` comes only from genre, `scene:*` crosses a sphere with an era, and
even the era needs one, since `takes_decades()` is itself a genre test.

An ISRC is the one identifier the two catalogues share, and **every Spotify
track carries one** — 500 of 500, measured. So Apple's catalogue can answer for
Spotify's rows.

**Why Apple's catalogue and not MusicBrainz or Spotify's own artist genres.**
`sphere`, `scene` and `era` are exact, case-sensitive dict lookups over Apple's
own strings in `music_dictionary.py` — `'J-Pop'` resolves and `'j-pop'` does
not. Apple returns Apple's vocabulary, so it needs no translation table. Every
other source would need one authored and kept in step, which is a second
vocabulary and the thing `0134` already warned about.

**Why offline, and why it emits SQL rather than writing.** The worker only
joins against what this leaves behind, so no MusicKit credential goes near the
Lambda and no network call sits inside the scoring path. `ontology` is not
exposed to PostgREST, and adding psycopg would make a tool that exists to be run
need a virtual environment somebody remembered to make — so this prints a
migration, exactly as `seed_from_csv.py` does. The catalogue then replays into
CI like any other authored data.

**The private key never enters this process.** Apple's catalogue endpoints need
a *developer* token — not a music-user token, which is the whole reason this
works server-side for somebody who has no Apple Music account. That token is an
ES256 JWT signed with a MusicKit `.p8`, and rather than load the key here, this
reads an already-minted token from the environment. One fewer place a
credential can be logged, and no third-party crypto dependency.

    export SUPABASE_SECRET_KEY=sb_secret_...
    export APPLE_MUSIC_DEVELOPER_TOKEN=eyJ...
    python3 tools/apple_catalog.py --user 7046df73-... \
        > supabase/migrations/00NN_the_catalogue_answers_for_spotify.sql

SQL goes to stdout; the coverage report goes to stderr, so a redirect leaves a
clean migration and still tells you whether it was worth applying.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from music_dictionary import (  # noqa: E402
    CLASSICAL_ERAS,
    DECADE_GENRES,
    GENRE_TRANSLATIONS,
    MARKED_SPHERE_GENRES,
    MEDIA_GENRES,
    UNMARKED_SPHERE_GENRES,
)

BASE = "https://fwnezkbesjoazlpaflbq.supabase.co"
APPLE = "https://api.music.apple.com/v1/catalog"

# **Pinned, and not the person's own storefront.** Genre names are localised, and
# the tables below are Apple's English strings — a `tw` storefront answers
# `華語流行` where `Mandopop` is wanted. `GENRE_TRANSLATIONS` covers 44 zh-Hant
# names and nothing else, so following each account's region would silently lose
# every sphere and scene for anybody outside those two locales.
STOREFRONT = "us"

# Matching `ComposerService.isrcsPerRequest`, which is the same request against
# the same endpoint from the other end of the system.
ISRCS_PER_REQUEST = 100

PAGE = 1000

# **What the exact-match tables actually hold.** `sphere`, `scene` and `era` are
# dict membership tests with no normalisation, so this is the set a returned
# genre has to land in to be worth more than a bare `genre:` concept. Built from
# the tables themselves rather than restated, or it would be a third copy to
# keep in step.
EXACT_MATCH_VOCABULARY = (
    set(GENRE_TRANSLATIONS)
    | set(GENRE_TRANSLATIONS.values())
    | set(CLASSICAL_ERAS)
    | set(DECADE_GENRES)
    | set(MARKED_SPHERE_GENRES)
    | set(UNMARKED_SPHERE_GENRES)
    | set(MEDIA_GENRES)
)


def env(name: str, hint: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"{name} is not set.\n\n{hint}\n")
    return value


def secret_key() -> str:
    return env(
        "SUPABASE_SECRET_KEY",
        "It bypasses row level security entirely, so it lives in your shell for\n"
        "the length of this run and nowhere else — not in the repo, not in a\n"
        "file, and not pasted into a chat: every key this project has lost went\n"
        "through a transcript.\n\n"
        "    export SUPABASE_SECRET_KEY=sb_secret_...",
    )


def developer_token() -> str:
    return env(
        "APPLE_MUSIC_DEVELOPER_TOKEN",
        "An ES256 JWT signed with a MusicKit private key. Mint it outside this\n"
        "tool so the `.p8` never enters this process:\n\n"
        "  - Apple Developer → Certificates, Identifiers & Profiles → Keys →\n"
        "    new key with MusicKit enabled. The `.p8` downloads once and is a\n"
        "    credential; treat it like `sb_secret_…`.\n"
        "  - Sign a JWT with alg ES256, `kid` = the key id, `iss` = the team id,\n"
        "    `iat` = now, `exp` = at most six months out.\n\n"
        "    export APPLE_MUSIC_DEVELOPER_TOKEN=eyJ...",
    )


def spotify_isrcs(key: str, user_id: str | None) -> list[str]:
    """Every distinct ISRC on a Spotify row, read from the legacy store.

    **`public.distilled_records` rather than the vault**, for one reason that is
    not preference: `semantic_private` is not exposed to PostgREST, and the two
    hold the same identifiers anyway — the ISRC is copied into
    `normalized_payload` unchanged. An account whose legacy rows have been
    deleted is simply not readable this way, which is a real limitation and the
    reason `--isrc-file` exists.
    """
    found: list[str] = []
    seen: set[str] = set()
    offset = 0
    while True:
        query = {
            "source": "eq.spotify",
            "select": "extra",
            "limit": str(PAGE),
            "offset": str(offset),
            "order": "item_id.asc",
        }
        if user_id:
            query["user_id"] = f"eq.{user_id}"
        url = f"{BASE}/rest/v1/distilled_records?" + urllib.parse.urlencode(query)
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
            sys.exit(f"distilled_records read failed: HTTP {error.code}\n{body}")
        for row in page:
            extra = row.get("extra")
            isrc = (extra or {}).get("isrc") if isinstance(extra, dict) else None
            if isrc and isrc not in seen:
                seen.add(isrc)
                found.append(isrc)
        if len(page) < PAGE:
            return found
        offset += PAGE


def catalogue(token: str, isrcs: list[str]) -> dict[str, dict]:
    """Apple's answer for a batch, keyed by the ISRC it was asked about.

    **No composer filter**, and that is deliberate rather than an omission.
    `ComposerService` drops any song whose `composerName` is empty
    (`ComposerService.swift:161`), which is right when the question is "who
    wrote this classical piece" and fatal here: most pop has no stated composer,
    so carrying that filter over would discard the genre this whole tool exists
    to fetch.
    """
    answers: dict[str, dict] = {}
    for start in range(0, len(isrcs), ISRCS_PER_REQUEST):
        batch = isrcs[start:start + ISRCS_PER_REQUEST]
        query = urllib.parse.urlencode({"filter[isrc]": ",".join(batch)})
        url = f"{APPLE}/{STOREFRONT}/songs?{query}"
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            sys.exit(
                f"Apple catalogue read failed on batch {start // ISRCS_PER_REQUEST}: "
                f"HTTP {error.code}\n{detail}\n\n"
                "A 401 here is the developer token — check it has not expired and\n"
                "that the key has MusicKit enabled. A 403 is the key being valid\n"
                "for something else."
            )
        for item in body.get("data", []):
            attributes = item.get("attributes") or {}
            isrc = attributes.get("isrc")
            if not isrc or isrc in answers:
                # **First edition wins.** One ISRC can return several songs — a
                # single, an album cut and a remaster share it — and they carry
                # the same genre. Taking the first is what `ComposerService`
                # does, so both ends of the system agree about which row spoke.
                continue
            answers[isrc] = {
                "genreNames": attributes.get("genreNames") or [],
                "composerName": (attributes.get("composerName") or "").strip(),
                "releaseDate": attributes.get("releaseDate") or "",
            }
        print(
            f"  batch {start // ISRCS_PER_REQUEST + 1}: asked {len(batch)}, "
            f"hold {len(answers)}",
            file=sys.stderr,
        )
    return answers


def report(isrcs: list[str], answers: dict[str, dict]) -> None:
    """What the run bought, on stderr, before anybody applies the migration.

    **The two numbers the plan asks for.** Coverage says whether the ISRC route
    works at all; the vocabulary hit rate says whether "Apple's genres need no
    translation" is true rather than assumed. A genre outside the exact-match
    tables still reaches a `genre:` concept — that matcher is case-insensitive —
    but reaches no sphere, no scene and no era, which is everything a person
    would actually see.
    """
    genred = {i: a for i, a in answers.items() if a["genreNames"]}
    counts = Counter(g for a in genred.values() for g in a["genreNames"])
    matched = {g: n for g, n in counts.items() if g in EXACT_MATCH_VOCABULARY}
    missing = {g: n for g, n in counts.items() if g not in EXACT_MATCH_VOCABULARY}

    def share(part: int, whole: int) -> str:
        return f"{part}/{whole} ({100.0 * part / whole:.1f}%)" if whole else "0/0"

    print("", file=sys.stderr)
    print(f"ISRCs asked          {len(isrcs)}", file=sys.stderr)
    print(f"answered by Apple    {share(len(answers), len(isrcs))}", file=sys.stderr)
    print(f"with a genre         {share(len(genred), len(isrcs))}", file=sys.stderr)
    print(f"distinct genres      {len(counts)}", file=sys.stderr)
    print(
        f"in the exact tables  {share(sum(matched.values()), sum(counts.values()))} "
        f"of mentions, {len(matched)}/{len(counts)} of strings",
        file=sys.stderr,
    )
    if missing:
        print("", file=sys.stderr)
        print(
            "Genres reaching a genre: concept but no sphere, scene or era —\n"
            "each is a candidate for MARKED_SPHERE_GENRES, UNMARKED_SPHERE_GENRES\n"
            "or DECADE_GENRES in tools/music_dictionary.py:",
            file=sys.stderr,
        )
        for genre, n in sorted(missing.items(), key=lambda kv: -kv[1])[:25]:
            print(f"    {n:5}  {genre}", file=sys.stderr)
    print("", file=sys.stderr)


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def emit(answers: dict[str, dict], description: str) -> None:
    """The migration, on stdout.

    **`payload_hash` is what makes re-running safe.** The unique key is
    `(provider, external_id, payload_hash)`, so an unchanged answer conflicts and
    does nothing while a changed one lands beside its predecessor — the same
    shape as the vault keeping both sides of a lineage rather than overwriting.

    **A song Apple answered for with no genre is still written**, because "asked
    and there is none" and "never asked" are different facts and only the first
    one is worth keeping. An ISRC Apple did not answer for at all gets no row
    and is asked again next run — which is the miss `ComposerService` also
    fails to record, and is harmless here for the reason it is not there: this
    runs by hand, occasionally, not on every distillation.

    `label` holds the genres rather than the song title. The title is not
    fetched and is not wanted; what makes this row worth reading at a glance is
    the answer it carries.
    """
    print(f"""-- {description}
--
-- Generated by `tools/apple_catalog.py`. Do not hand-edit: re-run the tool.
--
-- {len(answers)} songs, looked up by ISRC in Apple's `{STOREFRONT}` storefront and
-- kept as catalogue metadata rather than anybody's data — three fields, no
-- identifiers, no user attached. `ontology.external_entities` is where a
-- third-party catalogue belongs, and this is its first occupant.
--
-- Spotify states no genre at track level, so without this a Spotify library
-- reaches no sphere, no scene and no era. The join happens in `resolve.py` at
-- read time: `normalized_payload` is frozen by `guard_observation_immutable`,
-- and a catalogue is not the person's evidence.

begin;
""")
    if not answers:
        print("-- Nothing to insert: no ISRC returned a catalogue answer.")
        print("\ncommit;")
        return

    print(
        "insert into ontology.external_entities "
        "(id, provider, external_id, entity_kind, label, raw_payload, "
        "payload_hash, license_code, retrieved_at)\nvalues"
    )
    rows = []
    for isrc in sorted(answers):
        payload = answers[isrc]
        encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False)
        digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
        label = ", ".join(payload["genreNames"])
        rows.append(
            "  (gen_random_uuid(), 'apple_music_catalog', "
            f"{quote(isrc)}, 'song', {quote(label)}, "
            f"{quote(encoded)}::jsonb, {quote(digest)}, "
            "'apple_media_services', now())"
        )
    print(",\n".join(rows))
    print("on conflict (provider, external_id, payload_hash) do nothing;")
    print("""
commit;""")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", help="restrict to one account's Spotify rows")
    parser.add_argument(
        "--isrc-file",
        help="read ISRCs from a file, one per line, instead of from the database",
    )
    parser.add_argument(
        "--description",
        default="The catalogue answers for Spotify's ISRCs.",
        help="the migration's first line",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report coverage and emit nothing, for deciding whether to apply",
    )
    args = parser.parse_args()

    if args.isrc_file:
        with open(args.isrc_file, encoding="utf-8") as handle:
            isrcs = [line.strip() for line in handle if line.strip()]
    else:
        isrcs = spotify_isrcs(secret_key(), args.user)

    if not isrcs:
        sys.exit("No Spotify ISRCs found. Nothing to look up.")
    print(f"{len(isrcs)} distinct ISRCs to look up.", file=sys.stderr)

    answers = catalogue(developer_token(), isrcs)
    report(isrcs, answers)

    if args.dry_run:
        print("-- dry run: nothing emitted", file=sys.stderr)
        return 0
    emit(answers, args.description)
    return 0


if __name__ == "__main__":
    sys.exit(main())
