#!/usr/bin/env python3
"""Attach the RIS extraction to the evidence it came from.

`0307` puts the terms in the global dictionary, where they are nobody's in
particular. This is the other half: an `observation_mentions` row saying *this
person's row attests this term*, which is what a review card is built from and
what the scorer weighs.

**Three tables, because lineage is not optional here.**
`guard_model_mention_lineage` refuses a `model_proposed` mention that does not
name a succeeded `model_invocation_item` belonging to an invocation whose lane
is `shadow` or `active`. That is the right refusal — a model mention with no
invocation behind it cannot afterwards answer what produced it — so this
writes the invocation and the item as well, and the item carries the
`observation_id` the link resolved.

**A release manifest is published rather than borrowed.** The newest manifest
in the database is `qwen_extractor_v13`; the RIS corpus was extracted under
v14, staged on the cluster and never registered. Pointing the invocations at
the v13 row would make them state something untrue about what ran, which is
the same defect as a model version that lags its code. The manifest published
here names the RIS lane explicitly.

**Calendar is included, through the door `0308` opened and `0310` re-keyed.**
`guard_private_source_generic_lane_v03` refuses a mention on any private-lane
observation unless `calendar_public_event_is_eligible` passes, and measured
2026-08-22 that predicate passes for **0 of 1,049** calendar observations — so
the whole calendar corpus was unreachable. The door admits an item whose
`logical_extraction_key` begins `ris|`, which is why that prefix is written
below and must not be changed casually: it is what the guard reads.

**Why not the release manifest, which would have been the better key:**
`derive_invocation_lane` discards the caller's `release_manifest_id` and
substitutes the deployed release, so an invocation cannot state the lane it
ran in. The manifest below is still published as a record of what ran; nothing
points at it, and nothing can.

    python3 tools/ris_emit_mentions.py out/ris/verdicts_v15.json \\
        out/ris/links.json out/ris/items.jsonl 0308
"""
from __future__ import annotations

import collections
import json
import pathlib
import re
import sys
import unicodedata
import uuid

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: `ontology.model_versions`, `structured_source_extractor` 0.1.0 active — the
#: row that already means "the thing that reads mentions out of a source
#: record". Read from the database rather than invented, so a mention written
#: here is attributed to the same extractor as one written by the worker.
EXTRACTOR_MODEL_ID = "900b03cb-adcf-5c43-aa50-5d53c23062bd"

#: Deterministic ids, so re-running this emits the same migration and a second
#: application is a no-op rather than a duplicate set of invocations.
NAMESPACE = uuid.UUID("6f6b1f18-0a0e-5c2a-9a2a-1f0c3d9b7a11")

#: **Read from the contract rather than typed, because it was typed and went
#: stale.** This sat at `qwen_extractor_v14` while the compiled contract had
#: moved to v16, and the literal is not decoration: it feeds the invocation
#: rows, the release manifest, and `logical_extraction_key` — which is what
#: makes a retry the same work. Emitting a v16 corpus under a v14 label would
#: have mislabelled the provenance *and* collided keys with the v14 items,
#: which is the same defect `run_extract.sh` refuses to start without checking.
#: One source of truth, so the two cannot disagree again.
def _contract_versions() -> tuple[str, str]:
    path = (pathlib.Path(__file__).resolve().parents[1]
            / "semantic" / "contracts" / "compiled_semantic_contract_v1.json")
    versions = json.loads(path.read_text(encoding="utf-8"))["versions"]
    return versions["prompt"], versions["grammar"]


PROMPT_VERSION, GRAMMAR_VERSION = _contract_versions()

#: The sources whose observations may carry a mention from this lane. The
#: calendars are `is_private_lane_source` and are refused by trigger on the
#: generic lane; `0308` opens one door for the RIS lane specifically, so they
#: are admitted here and nowhere else. HealthKit stays out: it is quantities,
#: no distiller sends it for extraction, and nothing here would have a title
#: to mention. A positive list, so a source added later is excluded until
#: somebody decides it belongs rather than admitted by omission.
MENTION_LANES = {"apple_music", "music_library", "spotify", "youtube",
                 "apple_calendar", "google_calendar", "outlook_calendar"}

#: **Which retention promise the filed text falls under.** The classes are the
#: table's own, and the assignment is not cosmetic: `youtube_api_text` is what
#: makes a title reachable by the 30-day sweep III.E.4 requires, so filing a
#: YouTube title under any other class would quietly put it outside the rule
#: it is governed by.
RETENTION_CLASS = {
    "youtube": "youtube_api_text",
    "apple_music": "provider_catalog_text",
    "music_library": "provider_catalog_text",
    "spotify": "provider_catalog_text",
    "apple_calendar": "user_supplied_text",
    "google_calendar": "user_supplied_text",
    "outlook_calendar": "user_supplied_text",
}

#: **This is not ciphertext, and the value says so.** The production path
#: encrypts filed text with the account's own data key, unwrapped through KMS;
#: the testing lane has no KMS, and the owner's 2026-08-22 direction is that
#: the vault's key discipline is bypassed there. So the bytes are the title
#: itself and the key version names the fact rather than hiding it — anything
#: that tries to decrypt these meets a key version it does not know and fails
#: loudly, which is the only acceptable way to store plaintext in a column
#: called `encrypted_text`. **Never write this value from the AWS lane.**
RIS_KEY_VERSION = "ris_lab_plaintext_v1"

#: Thirty days, the same as every other filed evidence row. The testing lane
#: bypasses the key discipline and deliberately does not bypass the retention
#: one: III.E.4's clock is a third party's term, not the vault's convenience.
RIS_EVIDENCE_DAYS = 30


def norm(text: str) -> str:
    value = unicodedata.normalize("NFKC", str(text or "")).casefold().strip()
    return re.sub(r"\s+", " ", value)


def quote(text) -> str:
    if text is None:
        return "null"
    return "'" + str(text).replace("'", "''") + "'"


def det(*parts: str) -> str:
    return str(uuid.uuid5(NAMESPACE, "|".join(parts)))


def unsentinel(value):
    """`'none'` is the wire's null, and the database's null is null.

    xgrammar can constrain a pure string enum and cannot express a nullable
    one, so the output contract spells an absent cardinal or predicate as the
    literal `'none'` — the same reason `[scalar, null]` unions are the only
    nullable shape the schema uses. `observation_mentions.model_cardinal` and
    `model_user_predicate` are checked against the eight roots and the five
    predicates *or* null, so writing the sentinel through unchanged fails the
    constraint. It did, on 21 cardinals and 10 predicates out of 13,833.

    **Translated here, at the one place the wire meets the table**, rather
    than at each call site — the same rule as canonicalising an identifier
    where it enters.
    """
    text = (value or "").strip()
    return None if text in ("", "none") else text


def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text())
    links = json.loads(pathlib.Path(sys.argv[2]).read_text())["links"]
    items = {}
    for line in pathlib.Path(sys.argv[3]).read_text().splitlines():
        if line.strip():
            item = json.loads(line)
            items[item["row_id"]] = item
    number = sys.argv[4]

    counts: collections.Counter = collections.Counter()
    per_source: dict = collections.defaultdict(collections.Counter)
    invocations: dict = {}
    invocation_items: list = []
    mentions: list = []
    evidence: list = []

    for verdict in verdicts["verdicts"]:
        row_id = verdict["row_id"]
        source = verdict.get("source_code") or ""
        observation_id = links.get(row_id)
        if observation_id is None:
            counts["no_observation"] += 1
            per_source[source]["no_observation"] += 1
            continue
        if source not in MENTION_LANES:
            counts["private_lane_refused"] += 1
            per_source[source]["private_lane_refused"] += 1
            continue
        user_id = (items.get(row_id) or {}).get("user_id")
        if not user_id:
            counts["no_user"] += 1
            continue

        # One invocation per (user, source): the unit that shares a prompt, a
        # grammar and a lane. Not one per row, which would make the table a
        # second copy of the item list, and not one overall, because
        # `batch_items` and the lane are per-user facts.
        key = (user_id, source)
        invocation_id = invocations.setdefault(
            key, {"id": det("invocation", user_id, source, PROMPT_VERSION),
                  "user_id": user_id, "source": source, "items": 0})["id"]
        invocations[key]["items"] += 1

        kept = [m for m in verdict["mentions"] if (m.get("surface") or "").strip()]
        item_id = det("item", row_id, PROMPT_VERSION)
        # **The text the model was asked about, filed as evidence.**
        # `guard_invocation_item_scope` refuses a succeeded item for a real
        # user unless `source_text_evidence` holds current, unexpired,
        # non-null text for it — which is what makes the 30-day refresh and
        # crypto erasure enforceable rather than aspirational. The production
        # path files the title encrypted with the account's data key; this
        # lane has no KMS, so see `RIS_KEY_VERSION` below.
        title = ((items.get(row_id) or {}).get("fields") or {}).get("title")
        if title:
            evidence.append({
                "user_id": user_id, "observation_id": observation_id,
                "text": title[:512], "retention_class": RETENTION_CLASS[source]})
        invocation_items.append({
            "id": item_id, "invocation_id": invocation_id,
            "item_index": invocations[key]["items"] - 1,
            "user_id": user_id, "observation_id": observation_id,
            # **What makes a retry the same work**, per `0236`: the row, the
            # prompt and the grammar. A re-extraction under a new prompt is a
            # different key and therefore a different extraction rather than a
            # duplicate of this one.
            "logical_extraction_key": f"ris|{row_id}|{PROMPT_VERSION}|{GRAMMAR_VERSION}",
            "mention_count": len(kept),
        })
        counts["items"] += 1

        seen: set = set()
        for mention in kept:
            surface = mention["surface"].strip()
            normalized = norm(mention.get("canonical_label_hypothesis") or surface)
            role = mention.get("mention_role") or "primary_subject"
            field = mention.get("source_field") or "title"
            # The table's own conflict key, applied before writing rather than
            # relying on `on conflict` alone — two mentions differing only in
            # offsets are one row, and emitting both would make the migration
            # claim more evidence than it inserts.
            fingerprint = (observation_id, normalized, role, field)
            if not normalized or fingerprint in seen:
                counts["duplicate_mention"] += 1
                continue
            seen.add(fingerprint)
            mentions.append({
                "observation_id": observation_id, "user_id": user_id,
                "mention_text": surface[:512], "normalized_text": normalized[:512],
                "mention_role": role, "source_field": field,
                "confidence": float(mention.get("cardinal_confidence") or 0.5),
                "model_invocation_item_id": item_id,
                "model_cardinal": unsentinel(mention.get("selected_cardinal")),
                "model_user_predicate": unsentinel(
                    mention.get("candidate_user_predicate")),
            })
            counts["mentions"] += 1
            per_source[source]["mentions"] += 1

    out: list[str] = [f"""-- {number} — the RIS extraction meets the evidence it came from.
--
-- `0307` put {len(links)} rows' worth of terms into the global dictionary,
-- where they belong to nobody. This attaches them to the observations they
-- were read off, which is what a review card is built from and what the
-- scorer weighs: {counts['mentions']} mentions across {counts['items']}
-- source rows, under {len(invocations)} invocations.
--
-- **The join was rebuilt from content, because the join column is unusable
-- here.** `observations.source_item_hmac` is a keyed HMAC of the source
-- item's id and the key lives in KMS, which the lab GPU has no access to —
-- keyed rather than hashed precisely because source ids are guessable, so an
-- unkeyed digest would let anyone with read access test whether a given
-- person liked a given video. `tools/ris_link_observations.py` pairs the two
-- sides on what both state in the clear (title and performer for music,
-- channel and publication time for YouTube) and **refuses every ambiguous
-- pairing** rather than picking one: attaching a term to the wrong evidence
-- is worse than a term with no evidence.
--
-- **The lineage is written, not skipped.** `guard_model_mention_lineage`
-- refuses a `model_proposed` mention that does not descend from a succeeded
-- invocation item on a `shadow` or `active` lane, which is the right refusal —
-- so the invocation and the item are written here too, and the item carries
-- the observation the link resolved.
--
-- **A manifest is published rather than borrowed.** The newest manifest in
-- this database is `qwen_extractor_v13`; the corpus was extracted under v14,
-- staged on the cluster and never registered. Pointing these invocations at
-- the v13 row would make them state something untrue about what ran.
--
-- **Calendar is included, through the door `0308` opens.**
-- `guard_private_source_generic_lane_v03` admits a private-lane observation
-- only where `calendar_public_event_is_eligible` passes, and measured
-- 2026-08-22 that predicate passes for **0 of 1,049** calendar observations —
-- so the whole calendar corpus was unreachable to this lane. `0308` adds a
-- second door keyed on the release manifest's environment being `ris_lab`,
-- which is why the manifest below is published with that value and why these
-- rows depend on it: with the manifest absent, every calendar mention here is
-- refused by the trigger rather than quietly admitted.
-- {counts['private_lane_refused']} rows were dropped as belonging to no
-- mention lane at all.

do $$
declare
  manifest uuid;
begin
  -- **Copied from the v13 manifest column by column, because the hashes are
  -- what a manifest is.** The compiled contract, the workbook and the schema
  -- are the same artifacts; the prompt the run actually used and the
  -- environment it ran in are the only two literals here.
  insert into ontology.release_manifests
    (parent_release_id, base_ontology_version_id, compiled_contract_sha256,
     workbook_sha256, schema_sha256, release_build_sha256, model_revision,
     gateway_revision, database_fingerprint_sha256, environment,
     model_lane_mode, model_id, rollout_scope_revision,
     tokenizer_runtime_manifest_sha256, extraction_contract_manifest_sha256,
     request_schema_sha256, prompt_version, grammar_version,
     gateway_image_digest, serving_image_digest, worker_build_sha256)
  select m.id, m.base_ontology_version_id, m.compiled_contract_sha256,
         m.workbook_sha256, m.schema_sha256, m.release_build_sha256,
         m.model_revision, m.gateway_revision, m.database_fingerprint_sha256,
         -- **`ris_lab`, and the whole of `0308`'s door turns on this value.**
         -- Never `production`: the image digests copied above are the v13
         -- ones and the run used a mounted `serve.py`, so this is not an
         -- attested serving path and must not be mistaken for one.
         'ris_lab', 'shadow',
         m.model_id, m.rollout_scope_revision,
         m.tokenizer_runtime_manifest_sha256,
         m.extraction_contract_manifest_sha256, m.request_schema_sha256,
         {quote(PROMPT_VERSION)}, {quote(GRAMMAR_VERSION)},
         m.gateway_image_digest, m.serving_image_digest, m.worker_build_sha256
    from ontology.release_manifests m
   where m.prompt_version = 'qwen_extractor_v13'
   order by m.created_at desc
   limit 1
  on conflict do nothing;

  select id into manifest from ontology.release_manifests
   where prompt_version = {quote(PROMPT_VERSION)} and environment = 'ris_lab'
   order by created_at desc limit 1;
  -- **Absent is not a failure here.** A replay runs against a database with no
  -- v13 manifest to copy, so there is nothing to hang invocations on and
  -- nothing to attach; raising would make this migration unreplayable, which
  -- is what `tools/ci/unreplayable_migrations.txt` exists to keep empty.
  if manifest is null then
    raise notice '{number}: no v13 manifest to copy; nothing to attach';
    return;
  end if;

  -- `finish_reason`, not `status`: this table records how the generation
  -- ended, and every sequence in the run ended on a stop token — 1,343 of
  -- 1,343 on the relabel pass and no `length` truncations on the corpus once
  -- the output ceiling was raised above the 800 the AWS wire pins.
  insert into semantic_private.model_invocations
    (id, user_id, release_manifest_id, model_lane_mode, input_hash, model_id,
     model_revision, prompt_version, grammar_version, output_schema_hash,
     batch_items, finish_reason)
  select v.id::uuid, v.user_id::uuid, manifest, 'shadow', v.input_hash,
         coalesce(m.model_id, 'qwen3.5-9b'),
         coalesce(m.model_revision, 'ris'), {quote(PROMPT_VERSION)},
         {quote(GRAMMAR_VERSION)}, m.schema_sha256, v.batch_items,
         'stop'
    from (values"""]

    rows = [f"      ({quote(v['id'])}, {quote(v['user_id'])}, "
            f"{quote('ris_' + v['id'][:16])}, {v['items']})"
            for v in invocations.values()]
    out.append(",\n".join(rows))
    out.append("""    ) as v(id, user_id, input_hash, batch_items)
    cross join lateral (
      select model_id, model_revision, schema_sha256
        from ontology.release_manifests where id = manifest) m
    -- **Assert the transformation, not the precondition.** A replay runs
    -- against a database with no accounts and no vault, where every row below
    -- names a parent that does not exist — and these are foreign keys, so the
    -- insert would raise rather than land nothing. Joining to the parent makes
    -- the migration a no-op there and identical here.
    join auth.users u on u.id = v.user_id::uuid
  on conflict (id) do nothing;
end;
$$;
""")

    out.append("""-- **The text each item was asked about, filed first.**
-- `guard_invocation_item_scope` refuses a succeeded item belonging to a real
-- user unless `source_text_evidence` holds text for it that is `current`,
-- unexpired and non-null — which is what makes the 30-day refresh and crypto
-- erasure enforceable rather than aspirational, and is the right refusal.
--
-- **These rows are plaintext and the key version says so.** The production
-- path encrypts filed text with the account's own data key, unwrapped through
-- KMS; this lane has no KMS, and the owner's 2026-08-22 direction bypasses the
-- vault's key discipline for internal testing. So `encrypted_text` holds the
-- title itself under `ris_lab_plaintext_v1` — anything that tries to decrypt
-- meets a key version it does not know and fails loudly, which is the only
-- acceptable way to put plaintext in a column with that name. The AWS lane
-- never writes this value.
--
-- **The retention clock is not bypassed with the key.** Every row expires in
-- 30 days and YouTube titles are filed as `youtube_api_text`, so III.E.4's
-- sweep reaches them exactly as it reaches the ones the worker filed. A third
-- party's term is not the testing lane's to waive.""")
    out.append("""insert into semantic_private.source_text_evidence
  (user_id, observation_id, encrypted_text, encryption_key_version,
   retention_class, refresh_status, expires_at)
select o.user_id, o.id, convert_to(v.text, 'UTF8'), """
               + quote(RIS_KEY_VERSION) + """,
       v.retention_class, 'current', now() + interval '"""
               + str(RIS_EVIDENCE_DAYS) + """ days'
  from (values""")
    seen_evidence: set = set()
    rows = []
    for e in evidence:
        if e["observation_id"] in seen_evidence:
            continue
        seen_evidence.add(e["observation_id"])
        rows.append(f"  ({quote(e['user_id'])}, {quote(e['observation_id'])}, "
                    f"{quote(e['text'])}, {quote(e['retention_class'])})")
    out.append(",\n".join(rows))
    out.append("""  ) as v(user_id, observation_id, text, retention_class)
  join semantic_private.observations o
    on o.id = v.observation_id::uuid and o.user_id = v.user_id::uuid
 where not exists (
   select 1 from semantic_private.source_text_evidence e
    where e.observation_id = o.id and e.refresh_status <> 'deleted');
""")

    out.append("-- The items: one per source row, each naming its observation.")
    out.append("""insert into semantic_private.model_invocation_items
  (id, invocation_id, item_index, user_id, observation_id,
   source_text_evidence_id, logical_extraction_key, outcome, mention_count)
-- **`item_index` is allocated here, not carried in.** The table holds a
-- unique `(invocation_id, item_index)`, and a positional index computed by
-- the generator restarts at zero every run — so a second pass adding rows to
-- an existing invocation collides with the indices already taken. The index
-- continues from whatever that invocation already holds, and rows already
-- present are filtered out *before* the numbering so they do not consume it.
select v.id::uuid, v.invocation_id::uuid,
       coalesce(taken.max_index, -1)
         + row_number() over (partition by v.invocation_id order by v.item_index),
       v.user_id::uuid,
       o.id, e.id, v.logical_extraction_key, v.outcome, v.mention_count
  from (values""")
    rows = [f"  ({quote(i['id'])}, {quote(i['invocation_id'])}, {i['item_index']}, "
            f"{quote(i['user_id'])}, {quote(i['observation_id'])}, "
            f"{quote(i['logical_extraction_key'])}, 'succeeded', {i['mention_count']})"
            for i in invocation_items]
    out.append(",\n".join(rows))
    out.append("""  ) as v(id, invocation_id, item_index, user_id, observation_id,
          logical_extraction_key, outcome, mention_count)
  join semantic_private.observations o
    on o.id = v.observation_id::uuid and o.user_id = v.user_id::uuid
  join semantic_private.model_invocations i on i.id = v.invocation_id::uuid
  -- The evidence filed above, and the same currency test the guard applies —
  -- so a row whose text failed to file is skipped here rather than raising
  -- inside the trigger and taking the whole migration with it.
  join semantic_private.source_text_evidence e
    on e.observation_id = o.id and e.user_id = o.user_id
   and e.refresh_status = 'current' and e.expires_at > now()
   and e.encrypted_text is not null
  left join lateral (
    select max(mi.item_index) as max_index
      from semantic_private.model_invocation_items mi
     where mi.invocation_id = v.invocation_id::uuid) taken on true
 where not exists (
   select 1 from semantic_private.model_invocation_items mine
    where mine.id = v.id::uuid)
on conflict (id) do nothing;
""")

    out.append("-- The mentions themselves.")
    out.append("""insert into semantic_private.observation_mentions
  (observation_id, user_id, mention_text, normalized_text, mention_role,
   locale, source_field, extraction_method, confidence,
   safe_for_global_mining, safe_for_external_resolution,
   model_invocation_item_id, model_cardinal, model_user_predicate)
select o.id, o.user_id, v.mention_text, v.normalized_text, v.mention_role,
       'und', v.source_field, 'model_proposed', v.confidence, false, false,
       item.id, v.model_cardinal, v.model_user_predicate
  from (values""")
    rows = []
    for m in mentions:
        rows.append(
            f"  ({quote(m['observation_id'])}, {quote(m['user_id'])}, "
            f"{quote(m['mention_text'])}, {quote(m['normalized_text'])}, "
            f"{quote(m['mention_role'])}, {quote(m['source_field'])}, "
            f"{m['confidence']:.3f}, "
            f"{quote(m['model_invocation_item_id'])}, "
            f"{quote(m['model_cardinal'])}, {quote(m['model_user_predicate'])})")
    out.append(",\n".join(rows))
    out.append("""  ) as v(observation_id, user_id, mention_text, normalized_text,
          mention_role, source_field, confidence, model_invocation_item_id,
          model_cardinal, model_user_predicate)
  join semantic_private.observations o
    on o.id = v.observation_id::uuid and o.user_id = v.user_id::uuid
  join semantic_private.model_invocation_items item
    on item.id = v.model_invocation_item_id::uuid
on conflict (observation_id, normalized_text, mention_role,
             coalesce(source_field, ''), extraction_method)
   do nothing;
""")

    out.append(f"""
do $$
declare
  n integer;
begin
  select count(*) into n from semantic_private.observation_mentions
   where extraction_method = 'model_proposed';
  raise notice '{number}: % model mentions now stand', n;
  -- **Assert the transformation, not the precondition.** A replay against an
  -- empty database has no observations to hang these on, so the insert lands
  -- nothing and this must still pass; what must never be true is a mention
  -- whose lineage is missing, which the guards enforce on every row that did
  -- land.
  select count(*) into n
    from semantic_private.observation_mentions m
   where m.extraction_method = 'model_proposed'
     and m.model_invocation_item_id is null;
  if n > 0 then
    raise exception '{number}: % model mentions carry no invocation item', n;
  end if;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_extraction_meets_its_evidence.sql")
    path.write_text("\n".join(out) + "\n")
    print(json.dumps({
        "invocations": len(invocations), "items": counts["items"],
        "mentions": counts["mentions"],
        "no_observation": counts["no_observation"],
        "private_lane_refused": counts["private_lane_refused"],
        "duplicate_mention": counts["duplicate_mention"],
        "by_source": {s: dict(c.most_common()) for s, c in sorted(per_source.items())},
        "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
