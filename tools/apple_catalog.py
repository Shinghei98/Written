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

# **Imported rather than copied, and that is load-bearing.** An alias only ever
# matches if its stored `normalized_label` is byte-identical to what the resolver
# computes at read time, and `normalize_text` folds punctuation to spaces where
# `str.lower()` keeps it. `seed_from_csv.py:179` uses `.lower()` and `0134:42-45`
# records that trap; catalogue names arrive verbatim and are full of punctuation
# — `P!nk`, `Tyler, The Creator`, `A$AP Rocky` — so a second implementation here
# would mint every one of them unmatchable, with nothing reporting it.
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "semantic", "src",
    ),
)

from written_ontology.normalize import normalize_text  # noqa: E402

BASE = "https://fwnezkbesjoazlpaflbq.supabase.co"
APPLE = "https://api.music.apple.com/v1/catalog"


class CatalogueReadFailed(RuntimeError):
    """Apple refused the catalogue read.

    A raisable error rather than `sys.exit`, because this module is both a CLI
    and a file copied flat into the worker Lambda, where `SystemExit` is a
    `BaseException` and escapes the handler's `except Exception` — rollback,
    diagnostic and all. `aws/worker/catalogue.py` turns it into
    `CatalogueUnavailable`, which the handler already declines cleanly.
    """

# **Pinned, and not the person's own storefront.** Genre names are localised, and
# the tables below are Apple's English strings — a `tw` storefront answers
# `華語流行` where `Mandopop` is wanted. `GENRE_TRANSLATIONS` covers 44 zh-Hant
# names and nothing else, so following each account's region would silently lose
# every sphere and scene for anybody outside those two locales.
STOREFRONT = "us"

# **Apple's own cap, measured rather than chosen.** `filter[isrc]` refuses more
# than 25 values with `40005 Invalid Parameter Value` — *"the isrc filter only
# accepts 25 value(s) to filter on but 100 values were passed"* — so a batch of
# 100 is not slow, it is a 400 on the first request and no catalogue answer at
# all. Found the first time the worker ran with a developer token present, which
# is why it survived this long: with no token the call never reaches Apple.
#
# **`ComposerService.isrcsPerRequest` is 100 and this no longer matches it.**
# That is the app asking the same filter on the same endpoint, so it is subject
# to the same cap — see the note in `docs/NEXT-STEPS.md`. Deliberately not
# changed from here: it is a separate target needing a build and a device to
# verify, and matching a value that is wrong is not agreement.
ISRCS_PER_REQUEST = 25

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


def library_isrcs(key: str, user_id: str | None) -> list[str]:
    """Every distinct ISRC on a music row, read from the legacy store.

    **`public.distilled_records` rather than the vault**, for one reason that is
    not preference: `semantic_private` is not exposed to PostgREST, and the two
    hold the same identifiers anyway — the ISRC is copied into
    `normalized_payload` unchanged. An account whose legacy rows have been
    deleted is simply not readable this way, which is a real limitation and the
    reason `--isrc-file` exists.

    **Both music sources, not Spotify alone.** Apple Music stated no ISRC until
    `include=catalog` was added to its library reads — 0 of 3,102 rows carried
    one — so this could only ever have asked about Spotify. It now covers 319 of
    320 library songs and 226 of 227 playlist items, and an Apple-only account is
    the common case rather than the exotic one. Naming the two sources rather
    than taking every row is deliberate: an ISRC is a *recording* identifier, and
    only these two carry one.
    """
    found: list[str] = []
    seen: set[str] = set()
    offset = 0
    while True:
        query = {
            "source": "in.(spotify,apple_music)",
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


def catalogue(token: str, isrcs: list[str]) -> tuple[dict[str, dict], dict[str, str]]:
    """Apple's answer for a batch: songs keyed by ISRC, and the artists behind them.

    **No composer filter**, and that is deliberate rather than an omission.
    `ComposerService` drops any song whose `composerName` is empty
    (`ComposerService.swift:161`), which is right when the question is "who
    wrote this classical piece" and fatal here: most pop has no stated composer,
    so carrying that filter over would discard the genre this whole tool exists
    to fetch.

    **`include=artists` costs one query parameter on a request already being
    made**, which is the `part=topicDetails` shape: quota is per call, not per
    part. It is the whole of how a creator gets a stable identity — Apple's
    artist id — rather than a normalised string, so `Leehom Wang`, `王力宏` and
    `Wang Leehom` converge on one concept instead of fragmenting into three.
    `include=albums` is deliberately not asked for: it answers 504 against a
    `filter[isrc]` query, which `include=artists` does not.
    """
    answers: dict[str, dict] = {}
    artists: dict[str, str] = {}
    for start in range(0, len(isrcs), ISRCS_PER_REQUEST):
        batch = isrcs[start:start + ISRCS_PER_REQUEST]
        query = urllib.parse.urlencode({
            "filter[isrc]": ",".join(batch),
            "include": "artists",
        })
        url = f"{APPLE}/{STOREFRONT}/songs?{query}"
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            # **Raised, never `sys.exit`, because this file runs in two places.**
            # As a CLI, exiting is right and `main` still does it. Inside the
            # worker Lambda `sys.exit` raises `SystemExit`, which is a
            # `BaseException` — so it slipped past `except Exception` in
            # `handler.py`, taking the explicit `connection.rollback()` and the
            # payload-safe diagnostic with it. An expired developer token
            # therefore killed the invocation with nothing said anywhere.
            #
            # **Apple's response body is deliberately not carried.** The old
            # message pasted 400 characters of it, and that body echoes the
            # `filter[isrc]` it was asked about — identifiers from somebody's
            # library, which §12 does not allow into a log. The status code and
            # the batch number are what an operator actually acts on.
            error.read()
            raise CatalogueReadFailed(
                f"Apple catalogue read failed on batch "
                f"{start // ISRCS_PER_REQUEST}: HTTP {error.code}. "
                "A 401 is the developer token — check it has not expired and "
                "that the key has MusicKit enabled. A 403 is the key being "
                "valid for something else."
            ) from error
        for item in body.get("data", []):
            attributes = item.get("attributes") or {}
            isrc = attributes.get("isrc")
            # **Artists are collected from every song, including the ones whose
            # ISRC we already hold.** The "first edition wins" rule below is
            # about which row states the genre; it is not a reason to discard a
            # credit. A remaster can name an artist the single did not.
            # The games this song's album names, matched against each credit
            # below. Computed once per song rather than per credit.
            games = {_folded(title) for title in
                     game_titles_in(attributes.get("albumName") or "")}
            for identifier, name, genres in artists_in(item):
                # **First edition wins for the name; genres accumulate.** One
                # artist appears on many songs and Apple does not always repeat
                # the full genre list, so a union across appearances is a fuller
                # answer than whichever song happened to be seen first.
                existing = artists.setdefault(
                    identifier,
                    {"name": name, "genres": [], "isrcs": [], "is_game": False},
                )
                # **Sticky, and only ever set true.** One credit naming the game
                # is enough; a later song whose album says nothing must not
                # unsay it, which is the same union reasoning as the genres
                # above.
                if _folded(name) in games:
                    existing["is_game"] = True
                for genre in genres:
                    if genre not in existing["genres"]:
                        existing["genres"].append(genre)
                # **Which recordings named this artist**, so provenance can
                # follow the chain source → ISRC → song → artist → concept. The
                # artist step is the one that used to drop it, and the loss is
                # unrecoverable: measured across both accounts, only 10 of 817
                # artists are reachable from both Apple and Spotify, so which
                # source supplied one cannot be inferred afterwards.
                if isrc and isrc not in existing["isrcs"]:
                    existing["isrcs"].append(isrc)
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
                # **`albumName` is what tells a game from a person**, and it is a
                # field on a response already being made — the `part=` shape the
                # extraction rule licenses, costing no request and no quota.
                # See `game_titles_in`.
                "albumName": (attributes.get("albumName") or "").strip(),
            }
        print(
            f"  batch {start // ISRCS_PER_REQUEST + 1}: asked {len(batch)}, "
            f"hold {len(answers)} songs, {len(artists)} artists",
            file=sys.stderr,
        )
    return answers, artists


# **Longest first, and that ordering is load-bearing.** Searching for
# `game soundtrack` inside *Where Winds Meet Original Game Soundtrack* leaves
# `Original` on the end of the extracted title, so the specific markers must be
# tried before the general ones.
GAME_SOUNDTRACK_MARKERS = (
    "original video game soundtrack",
    "original game soundtrack",
    "video game soundtrack",
    "game soundtrack",
)


def _folded(text: str) -> str:
    """Whitespace-collapsed casefold, for comparing a credit to a title."""
    return " ".join((text or "").split()).casefold()


def game_titles_in(album_name: str) -> list[str]:
    """The game an album names, if its title says it is a game soundtrack.

    **A read, not an inference.** Apple states the album as *"When the Wind
    Rises (Where Winds Meet Original Game Soundtrack (Qinghe))"*, and the game
    names itself immediately before the marker. Nothing here decides what a
    thing is about; it takes the name Apple printed.

    **Why not the artist's `genreNames`, which say `Video Game` outright.**
    Because they say it of the *composer* too. Measured 2026-08-15: the three
    catalogue artists carrying that genre are `Where Winds Meet` (the game),
    `Yida` (the person who wrote its music) and `星戈音樂` (a studio). Routing on
    the genre would have turned a songwriter into a video game, and he is
    currently an eligible term on a real account at 0.424. The album title
    separates them because only the game is named in it.

    Returns a list because one album can name more than one marker form; the
    caller matches a credit against any of them.
    """
    folded = _folded(album_name)
    for marker in GAME_SOUNDTRACK_MARKERS:
        index = folded.find(marker)
        if index < 0:
            continue
        # **Present but naming nothing.** An album called exactly *Original Game
        # Soundtrack* states that it is one and never says which, so there is no
        # title to take. Returning here rather than continuing is the same rule
        # as below: a longer marker having matched, a shorter one can only cut
        # the same words in a worse place.
        if index == 0:
            return []
        prefix = album_name[:index].rstrip()
        # **Two shapes, and the second is not a special case.** Either the
        # marker opens its own bracket — *Final Fantasy XIV: Endwalker (Original
        # Video Game Soundtrack)* — in which case the game is everything before
        # that bracket; or it trails the game inside one — *When the Wind Rises
        # (Where Winds Meet Original Game Soundtrack (Qinghe))* — in which case
        # the game begins at the last bracket that opened.
        if prefix and prefix[-1] in "([{（【":
            title = prefix[:-1]
        else:
            title = prefix
            for opener in "([{（【":
                title = title.rsplit(opener, 1)[-1]
        title = title.strip(" -–—:,·|")
        # **Return on the first marker, matched or not.** Falling through to the
        # shorter markers after a match extracts from the wrong side of the same
        # words: `Original Video Game Soundtrack` also contains `game
        # soundtrack`, and searching for that leaves `Original` as the title.
        return [title] if title else []
    return []


def artists_in(item: dict) -> list[tuple[str, str, list[str]]]:
    """The `(id, name, genres)` of every artist credited on one catalogue song.

    `include=artists` embeds the artist resources inside the song's
    `relationships`, so this reads them where the response puts them rather than
    making a second call. **An artist with no id is skipped**: the id is the
    whole point, and a nameless or idless credit would mint a concept keyed on
    nothing.

    **The genres are what give a minted concept a parent.** A creator with no
    `broader` edge is a floating node — `concept_block` answers null, so the term
    lands under "Other" and belongs to no hub. That is the difference between
    minting vocabulary and minting *structure*, and it is why `0162` had to exist
    for eight k-pop members who had been minted without one. An artist resource
    states its own `genreNames`; taking them costs nothing here and saves a
    hand-written migration per artist later.

    An artist without stated genres is still returned — it is a real artist, it
    simply gets no parent, and that is a better answer than dropping them.
    """
    relationships = item.get("relationships") or {}
    artists = relationships.get("artists") or {}
    found: list[tuple[str, str, list[str]]] = []
    for entry in artists.get("data") or []:
        identifier = (entry.get("id") or "").strip()
        attributes = entry.get("attributes") or {}
        name = (attributes.get("name") or "").strip()
        genres = [g for g in (attributes.get("genreNames") or []) if g]
        if identifier and name:
            found.append((identifier, name, genres))
    return found


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


def emit(answers: dict[str, dict], artists: dict[str, str], description: str) -> None:
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
        emit_artists(artists)
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
    emit_artists(artists)
    print("""
commit;""")


def emit_artists(artists: dict[str, str]) -> None:
    """The artists, as catalogue entities keyed on Apple's own id.

    **The normalised label is computed here and carried in `raw_payload`.** The
    migration that mints concepts from these rows runs in SQL, and SQL cannot
    reproduce `normalize_text` — it is Unicode-category-driven, folding
    punctuation and symbols to spaces while keeping every script. Precomputing
    it is what lets the minting stay a set operation over data already in the
    database, with one implementation of the rule rather than two.

    `entity_kind='artist'` is what separates these from the `'song'` rows above;
    both share the provider, so a later sweep or refresh sees one catalogue.
    """
    if not artists:
        print("\n-- No artists returned: nothing to mint a vocabulary from.")
        return
    print(f"""
-- {len(artists)} distinct artists, from the same responses. No extra request
-- was made for these: `include=artists` rides on the ISRC query above.
--
-- **Identity is Apple's artist id, never the name.** A name is a label; an id
-- is what makes `Leehom Wang`, `王力宏` and `Wang Leehom` one artist rather than
-- three concepts that can never match each other.
insert into ontology.external_entities
  (id, provider, external_id, entity_kind, label, raw_payload,
   payload_hash, license_code, retrieved_at)
values""")
    rows = []
    for identifier in sorted(artists):
        entry = artists[identifier]
        name = entry["name"]
        # **Both the genre and its normalised form**, because the migration that
        # mints `broader` edges runs in SQL and SQL cannot reproduce
        # `normalize_text`. Same reason the artist's own normalised name is
        # carried: one implementation of the fold, computed where the fold lives.
        payload = {
            "name": name,
            "normalized": normalize_text(name),
            "genres": list(entry["genres"]),
            "genres_normalized": [normalize_text(g) for g in entry["genres"]],
        }
        encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False)
        digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
        rows.append(
            "  (gen_random_uuid(), 'apple_music_catalog', "
            f"{quote(identifier)}, 'artist', {quote(name)}, "
            f"{quote(encoded)}::jsonb, {quote(digest)}, "
            "'apple_media_services', now())"
        )
    print(",\n".join(rows))
    print("on conflict (provider, external_id, payload_hash) do nothing;")


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
        isrcs = library_isrcs(secret_key(), args.user)

    if not isrcs:
        sys.exit("No ISRCs found on any Spotify or Apple Music row. Nothing to look up.")
    print(f"{len(isrcs)} distinct ISRCs to look up.", file=sys.stderr)

    # The CLI still exits on a refused read — `catalogue` raises now, because
    # the worker copies this file and `SystemExit` escapes its handler, and this
    # is where the exit belongs instead.
    try:
        answers, artists = catalogue(developer_token(), isrcs)
    except CatalogueReadFailed as failure:
        sys.exit(str(failure))
    report(isrcs, answers)
    print(f"distinct artists       {len(artists)}", file=sys.stderr)

    if args.dry_run:
        print("-- dry run: nothing emitted", file=sys.stderr)
        return 0
    emit(answers, artists, args.description)
    return 0


if __name__ == "__main__":
    sys.exit(main())
