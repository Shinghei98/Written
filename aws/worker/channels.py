"""Subscribed channels become vocabulary, the way catalogue artists do.

**Measured 2026-08-15**: 1,396 active YouTube observations reaching 91 concepts,
every one matched against vocabulary that already existed, and
`ontology.youtube_channels` frozen at the 298 rows `0135` wrote by hand on the
13th — none added by the re-distillation on the 15th that brought new
subscriptions with it. So YouTube resolved and never minted, which is why
`Hearthstone` needed a migration before it could be a concept.

**No network, no quota, no key.** Titles come from `public.distilled_records`,
where a liked video carries the channel id in `extra` and the title in
`creator`, and a subscription row *is* the channel. The vault does not hold the
title at all — a subscription's projection is `topics`, `subscriber_count` and
`tags` — so this is the read-derive-discard pattern the policy asks for, taken
from the catalogue rather than from stored evidence.

**Two calls because two identities.** `semantic_worker` may read
`ontology.youtube_channels` and may not read `public.distilled_records`, so the
refresh is `security definer` on the server; the mint takes its rows from here
because the normalised form must be `normalize_text`'s, which SQL cannot
reproduce.
"""

from __future__ import annotations

import json
from typing import Any

from written_ontology.normalize import normalize_text

REFRESH = "select semantic_private.refresh_youtube_channels() as added"

# **Every catalogued channel, not only the new ones.** A channel catalogued
# before this existed has never been offered to the vocabulary, and the mint
# refuses what already resolves — so passing the whole catalogue is how the
# backlog is cleared, and it costs one pass over a few hundred rows.
SELECT_CHANNELS = """
select youtube_channel_id, canonical_title
  from ontology.youtube_channels
 where lifecycle_state = 'active'
   and coalesce(btrim(canonical_title), '') <> ''
 order by youtube_channel_id
"""

MINT = "select semantic_private.mint_youtube_channels(%(channels)s::jsonb) as receipt"


def mint_channels(connection) -> dict[str, Any]:
    """Catalogue what the distillations named, then offer it as vocabulary.

    Returns the server's receipt, with the refresh count folded in. A run that
    mints nothing publishes nothing: the gate is inside the SQL function, where
    the answer is known, rather than here where it is guessed.
    """
    with connection.cursor() as cursor:
        cursor.execute(REFRESH)
        added = cursor.fetchone()["added"]

    with connection.cursor() as cursor:
        cursor.execute(SELECT_CHANNELS)
        rows = cursor.fetchall()

    channels = [
        {
            "channel_id": row["youtube_channel_id"],
            "title": row["canonical_title"].strip(),
            # **Computed here and never in SQL.** An alias only matches if its
            # stored form is byte-identical to what the resolver computes, and
            # `0184` is the migration that had to repair three concepts minted
            # without this.
            "normalized": normalize_text(row["canonical_title"]),
        }
        for row in rows
        if row["canonical_title"] and normalize_text(row["canonical_title"])
    ]

    if not channels:
        return {"catalogued": added, "minted": 0, "published": False}

    with connection.cursor() as cursor:
        cursor.execute(MINT, {"channels": json.dumps(channels, ensure_ascii=False)})
        receipt = cursor.fetchone()["receipt"]

    receipt["catalogued"] = added
    return receipt
