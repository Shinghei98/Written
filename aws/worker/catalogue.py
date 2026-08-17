"""Fetch Apple's catalogue for the ISRCs a user's library names, server-side.

**The same fetch `tools/apple_catalog.py` performs, not a second one.** That
module is copied into the bundle beside the music dictionary, exactly as
`music_dictionary.py` is, so `catalogue()` and `artists_in()` have one
implementation and one place to fix. What lives here is the part that has no
meaning on a laptop: which ISRCs are still missing, and handing the answers to
the database.

**Why it moved server-side at all.** Until now a person ran the tool and applied
a migration, so a new user's artists stayed invisible until somebody did that.
`apple_catalog.py`'s own header records that keeping the MusicKit credential off
the Lambda was deliberate; this reverses that on purpose, and the cost is that a
developer token now lives in the runtime.

**The token is pre-minted, never the `.p8`.** Apple wants an ES256 JWT and the
signing key would let anything mint one; a token expires within six months and
can only read a public catalogue. Unset is a deliberate off switch — the shape
`CALENDAR_CLASSIFIER_ARN` already uses — and an *expired* token must fail loudly
rather than quietly stop enriching, which is why a refusal is raised rather than
counted.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any

from apple_catalog import (
    ISRCS_PER_REQUEST,
    CatalogueReadFailed,
    artists_in,
    catalogue,
)
from written_ontology.normalize import normalize_text


# Bounded per job. A first-time library is ~1,300 ISRCs and Apple takes **25**
# per request, so this is fifty-two calls rather than the thirteen this comment
# claimed while `ISRCS_PER_REQUEST` was 100 — the cap is Apple's and is measured,
# not chosen. The ceiling exists so one enormous library cannot spend a whole
# Lambda timeout, and what it leaves behind is picked up by the next
# distillation rather than lost.
#
# **2,000 is eighty calls against a 300-second timeout**, so the headroom is the
# per-call latency staying under ~3.5s. That is comfortable today and is the
# number to revisit first if a mint ever times out, since lowering it costs a
# person nothing but another distillation.
MAX_ISRCS_PER_JOB = 2_000


class CatalogueUnavailable(RuntimeError):
    """No usable developer token. Distinguished so the caller can decline."""


SELECT_MISSING_ISRCS = """
select o.normalized_payload ->> 'isrc'      as isrc,
       array_agg(distinct o.source_code)    as sources
  from semantic_private.observations o
 where o.user_id = any(%(user_ids)s)
   and o.lifecycle_state = 'active'
   and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
   and not exists (
     select 1
       from ontology.external_entities e
      where e.provider = 'apple_music_catalog'
        and e.entity_kind = 'song'
        and e.external_id = o.normalized_payload ->> 'isrc'
        -- **A cached answer that predates a field we now read is not a
        -- complete answer.** `albumName` is what tells a game soundtrack from
        -- a person, and every row stored before it was kept lacks the key
        -- entirely — so those ISRCs are asked again, once, and then satisfy
        -- this clause forever. Self-limiting: it is a key test, not a
        -- timestamp, so nothing re-fetches on a schedule.
        and e.raw_payload ? 'albumName'
        -- **And `name`, which is the identity work's prerequisite.** 2,329 rows
        -- were cached with the genre list as their label and no track name at
        -- all, so a recording concept minted from them would have been called
        -- `"Pop, Music"`. Requiring the key is what makes those rows re-ask
        -- exactly once. Storing the field without requiring it would have left
        -- them looking complete forever, which is the same silence the label
        -- itself sat in.
        and e.raw_payload ? 'name'
   )
 group by 1
 -- **Deterministic, because the limit makes this a page.** Without an order the
 -- planner may return any 2,000 of the outstanding ISRCs, and a later pass may
 -- return an overlapping set — so a long tail can be re-asked indefinitely while
 -- some ISRC is never reached. Ordering by the ISRC makes successive pages
 -- successive: the anti-join above removes what was fetched, so the next call
 -- starts where this one stopped.
 order by 1
 limit %(limit)s
"""


def developer_token() -> str:
    token = (os.environ.get("APPLE_MUSIC_DEVELOPER_TOKEN") or "").strip()
    if not token:
        raise CatalogueUnavailable("APPLE_MUSIC_DEVELOPER_TOKEN is unset")
    return token


def missing_isrcs(connection, user_ids: list[str]) -> dict[str, list[str]]:
    """ISRCs these users name that the catalogue has never answered for.

    **Asked of the vault, not of the job.** The payload carries a user and
    nothing else precisely so this question is answered when the work runs; a
    list computed at arming time would be stale by the time the debounce
    expired, which is the whole point of the debounce.

    **Returns the sources each identifier was seen in, not a bare list.** One
    recording can appear in two libraries, and which sources named it is only
    knowable here — measured across both accounts, only 10 of 817 artists are
    reachable from both Apple and Spotify, so this cannot be reconstructed later
    by re-deriving from one of them and seeing what matches.
    """
    if not user_ids:
        return {}
    with connection.cursor() as cursor:
        cursor.execute(
            SELECT_MISSING_ISRCS,
            {"user_ids": user_ids, "limit": MAX_ISRCS_PER_JOB},
        )
        return {
            row["isrc"]: list(row["sources"] or [])
            for row in cursor.fetchall() if row["isrc"]
        }


def _hashed(payload: dict[str, Any]) -> tuple[dict[str, Any], str]:
    """A payload and the digest the uniqueness key is built from.

    `external_entities` is unique on `(provider, external_id, payload_hash)`, so
    an unchanged answer conflicts and does nothing while a changed one lands
    beside its predecessor. The encoding must match `tools/apple_catalog.py`'s
    or the same answer would hash two ways and re-store on every run.
    """
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return payload, hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def fetch(
    token: str, sources_by_isrc: dict[str, list[str]]
) -> tuple[list[dict], list[dict], list[dict]]:
    """Songs, artists, and which app source named each — shaped for the mint.

    The normalised forms are computed here rather than in SQL because
    `normalize_text` is a Unicode-category fold that Postgres cannot reproduce,
    and an alias whose stored form differs from what the resolver computes is
    minted unmatchable with nothing reporting it.

    **An artist inherits the sources of every recording that named it**, which
    is a union rather than a first-wins: a performer on one Apple track and one
    Spotify track is supplied by both, and recording only the first would report
    them as belonging to whichever happened to be read first. That mistake looks
    correct until the day the restriction is applied.
    """
    isrcs = sorted(sources_by_isrc)
    answers, artists = catalogue(token, isrcs)

    songs: list[dict[str, Any]] = []
    for isrc in sorted(answers):
        payload, digest = _hashed(answers[isrc])
        songs.append({
            "isrc": isrc,
            # The track name, which is what a recording concept will be called.
            # Falls back to the genres only so a malformed answer still stores
            # something readable; such a row fails the `name` completeness test
            # above and is asked again.
            "label": payload.get("name") or ", ".join(payload.get("genreNames") or []),
            "payload_hash": digest,
            **payload,
        })

    provenance: list[dict[str, str]] = [
        {"external_id": isrc, "entity_kind": "song", "source_code": source}
        for isrc in isrcs
        for source in sources_by_isrc.get(isrc, ())
        if isrc in answers
    ]

    shaped: list[dict[str, Any]] = []
    for identifier in sorted(artists):
        entry = artists[identifier]
        payload, digest = _hashed({
            "name": entry["name"],
            "normalized": normalize_text(entry["name"]),
            "genres": list(entry["genres"]),
            "genres_normalized": [normalize_text(g) for g in entry["genres"]],
            # **What the mint routes on.** True when an album named this credit
            # as the game it is the soundtrack to — Apple's own words, never a
            # judgement about the name. Adding the key changes every artist's
            # `payload_hash`, so each is stored once more and `mint_candidate`
            # takes the newest by `retrieved_at`; that is the intended way a
            # catalogue answer is superseded here.
            "is_game": bool(entry.get("is_game")),
        })
        shaped.append({
            "external_id": identifier,
            "payload_hash": digest,
            **payload,
        })
        inherited: set[str] = set()
        for isrc in entry.get("isrcs", ()):
            inherited.update(sources_by_isrc.get(isrc, ()))
        provenance += [
            {"external_id": identifier, "entity_kind": "artist", "source_code": source}
            for source in sorted(inherited)
        ]

    return songs, shaped, provenance


RECORD_PROVENANCE = """
select ontology.record_catalogue_provenance(%(rows)s::jsonb) as written
"""

MINT = """
select semantic_private.mint_vocabulary_from_catalogue(
         %(user_ids)s::uuid[], %(songs)s::jsonb, %(artists)s::jsonb
       ) as receipt
"""

# **The genre mint, which `0191` said ran continuously and did not.**
#
# It reads the genre strings Apple stated on the artist rows already in
# `ontology.external_entities` — no network, no token — and mints a genre named
# after one we already hold (`british pop` under `pop`) by the suffix rule
# argued in `0191`. Until `0202` it carried `revoke all` and no grant, so this
# call could not have been written: `semantic_worker` was not permitted to make
# it.
#
# **Without it an unmatched genre string is discarded in silence.**
# `mint_vocabulary_from_catalogue` joins stated genres to *existing* genre
# concepts and inserts none, so the artist simply gets no genre parent and
# blocks to `hub:music`.
MINT_GENRES = """
select semantic_private.mint_genres_from_stated_strings() as receipt
"""


def mint_for(connection, user_ids: list[str]) -> dict[str, Any]:
    """Fetch what is missing for these users, then let the database mint.

    **The worker never writes vocabulary.** `semantic_worker` holds no insert on
    any `ontology` table and `0070` asserts it cannot publish a version; it may
    only call `mint_vocabulary_from_catalogue`, which is `security definer`. The
    split is deliberate — the thing reachable from a queue should not be able to
    rewrite shared vocabulary at will.
    """
    sources_by_isrc = missing_isrcs(connection, user_ids)
    songs: list[dict] = []
    artists: list[dict] = []
    provenance: list[dict] = []
    if sources_by_isrc:
        try:
            songs, artists, provenance = fetch(developer_token(), sources_by_isrc)
        except CatalogueReadFailed as refusal:
            # **A refused read is the same fact as an absent token**, and the
            # handler already has a branch for that: roll back, say why, decline
            # the job rather than retrying it forever against a credential that
            # will not start working. Re-raised as the type that branch names,
            # so there is one way to be unable to reach the catalogue rather
            # than two.
            raise CatalogueUnavailable(str(refusal)) from refusal

    # **Recorded before the mint, and separately from it.** Provenance is a fact
    # about the lookup, so it holds whether or not this pass ends in a published
    # version — and a mint that finds nothing new still learned which source
    # named the recordings it asked about.
    if provenance:
        with connection.cursor() as cursor:
            cursor.execute(RECORD_PROVENANCE, {
                "rows": json.dumps(provenance, ensure_ascii=False),
            })
            provenance_written = cursor.fetchone()["written"]
    else:
        provenance_written = 0

    # **Genres first, and the order is the point.** This publishes a version if
    # it mints anything, so the artist mint below then reads a vocabulary that
    # already contains the genres — and an artist whose only genre is new gets
    # its parent in the same pass. Reversed, the artist and its genre would need
    # two distillations to meet, and the artist would sit under `hub:music`
    # until the second.
    #
    # **After the fetch, so it sees the rows this pass just wrote.** The function
    # itself needs no network and no token — it reads stored catalogue rows — but
    # placing it here rather than at the top of `mint_for` is what lets a genre
    # that arrived moments ago be minted now instead of next time. The cost is
    # that a pass which fails on the token never reaches it, which is the right
    # trade: that pass has learned nothing new to mint from.
    with connection.cursor() as cursor:
        cursor.execute(MINT_GENRES)
        genre_receipt = cursor.fetchone()["receipt"]

    with connection.cursor() as cursor:
        cursor.execute(MINT, {
            "user_ids": user_ids,
            "songs": json.dumps(songs, ensure_ascii=False),
            "artists": json.dumps(artists, ensure_ascii=False),
        })
        receipt = cursor.fetchone()["receipt"]

    # Reported rather than folded in: a pass that minted three genres and no
    # artists is a different fact from one that minted neither, and a single
    # `minted` count would make them read the same.
    receipt["genres"] = genre_receipt
    receipt["isrcs_looked_up"] = len(sources_by_isrc)
    receipt["isrcs_capped"] = len(sources_by_isrc) >= MAX_ISRCS_PER_JOB
    receipt["provenance_written"] = provenance_written
    return receipt
