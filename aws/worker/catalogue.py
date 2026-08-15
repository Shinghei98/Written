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

from apple_catalog import ISRCS_PER_REQUEST, artists_in, catalogue
from written_ontology.normalize import normalize_text


# Bounded per job. A first-time library is ~1,300 ISRCs and Apple takes 100 per
# request, so this is thirteen calls; the ceiling exists so one enormous library
# cannot spend a whole Lambda timeout, and what it leaves behind is picked up by
# the next distillation rather than lost.
MAX_ISRCS_PER_JOB = 2_000


class CatalogueUnavailable(RuntimeError):
    """No usable developer token. Distinguished so the caller can decline."""


SELECT_MISSING_ISRCS = """
select distinct o.normalized_payload ->> 'isrc' as isrc
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
   )
 limit %(limit)s
"""


def developer_token() -> str:
    token = (os.environ.get("APPLE_MUSIC_DEVELOPER_TOKEN") or "").strip()
    if not token:
        raise CatalogueUnavailable("APPLE_MUSIC_DEVELOPER_TOKEN is unset")
    return token


def missing_isrcs(connection, user_ids: list[str]) -> list[str]:
    """ISRCs these users name that the catalogue has never answered for.

    **Asked of the vault, not of the job.** The payload carries a user and
    nothing else precisely so this question is answered when the work runs; a
    list computed at arming time would be stale by the time the debounce
    expired, which is the whole point of the debounce.
    """
    if not user_ids:
        return []
    with connection.cursor() as cursor:
        cursor.execute(
            SELECT_MISSING_ISRCS,
            {"user_ids": user_ids, "limit": MAX_ISRCS_PER_JOB},
        )
        return [row["isrc"] for row in cursor.fetchall() if row["isrc"]]


def _hashed(payload: dict[str, Any]) -> tuple[dict[str, Any], str]:
    """A payload and the digest the uniqueness key is built from.

    `external_entities` is unique on `(provider, external_id, payload_hash)`, so
    an unchanged answer conflicts and does nothing while a changed one lands
    beside its predecessor. The encoding must match `tools/apple_catalog.py`'s
    or the same answer would hash two ways and re-store on every run.
    """
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return payload, hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def fetch(token: str, isrcs: list[str]) -> tuple[list[dict], list[dict]]:
    """Songs and artists, shaped for `mint_vocabulary_from_catalogue`.

    The normalised forms are computed here rather than in SQL because
    `normalize_text` is a Unicode-category fold that Postgres cannot reproduce,
    and an alias whose stored form differs from what the resolver computes is
    minted unmatchable with nothing reporting it.
    """
    answers, artists = catalogue(token, isrcs)

    songs: list[dict[str, Any]] = []
    for isrc in sorted(answers):
        payload, digest = _hashed(answers[isrc])
        songs.append({
            "isrc": isrc,
            "label": ", ".join(payload.get("genreNames") or []),
            "payload_hash": digest,
            **payload,
        })

    shaped: list[dict[str, Any]] = []
    for identifier in sorted(artists):
        entry = artists[identifier]
        payload, digest = _hashed({
            "name": entry["name"],
            "normalized": normalize_text(entry["name"]),
            "genres": list(entry["genres"]),
            "genres_normalized": [normalize_text(g) for g in entry["genres"]],
        })
        shaped.append({
            "external_id": identifier,
            "payload_hash": digest,
            **payload,
        })

    return songs, shaped


MINT = """
select semantic_private.mint_vocabulary_from_catalogue(
         %(user_ids)s::uuid[], %(songs)s::jsonb, %(artists)s::jsonb
       ) as receipt
"""


def mint_for(connection, user_ids: list[str]) -> dict[str, Any]:
    """Fetch what is missing for these users, then let the database mint.

    **The worker never writes vocabulary.** `semantic_worker` holds no insert on
    any `ontology` table and `0070` asserts it cannot publish a version; it may
    only call `mint_vocabulary_from_catalogue`, which is `security definer`. The
    split is deliberate — the thing reachable from a queue should not be able to
    rewrite shared vocabulary at will.
    """
    isrcs = missing_isrcs(connection, user_ids)
    songs: list[dict] = []
    artists: list[dict] = []
    if isrcs:
        songs, artists = fetch(developer_token(), isrcs)

    with connection.cursor() as cursor:
        cursor.execute(MINT, {
            "user_ids": user_ids,
            "songs": json.dumps(songs, ensure_ascii=False),
            "artists": json.dumps(artists, ensure_ascii=False),
        })
        receipt = cursor.fetchone()["receipt"]

    receipt["isrcs_looked_up"] = len(isrcs)
    receipt["isrcs_capped"] = len(isrcs) >= MAX_ISRCS_PER_JOB
    return receipt
