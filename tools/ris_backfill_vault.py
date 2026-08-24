#!/usr/bin/env python3
"""Re-project a distillation the vault never received, server-side.

**One account's Spotify never dual-wrote.** `7046df73` holds 593 Spotify rows
in `distilled_records`, is still connected, and has **zero** raw rows and zero
observations — no `user_deleted` marker, no erasure, nothing. The other two
accounts' Spotify was captured (and in two cases later erased by a real
deletion, which is left alone). This is a dual-write that never ran, most
likely a build predating Spotify's entry in `AppConfig.semanticIngestionSources`.

**So it is ours to fix, and the rule says so.** *A change that needs data
re-projected is our problem to solve server-side*, and *"ask them to distil
again" is a bug report about us* — the owner's standing requirement, given
with the consent that nobody re-distils for the project.

**It goes through `ingest_source_records_v031`, not around it.** That function
is the one entry point the ingestion identity may call: it opens the run,
records the scopes, writes the raw rows, promotes the observations, writes the
run items and finalizes. Hand-writing observations would mean reimplementing
that protocol beside it and getting the guards wrong — `close_unpromotable_ingestion_run`
exists precisely because a migration that knows better than a guard is how the
guard stops meaning anything.

**Two values are marked rather than faked, and both are visible.**

  * `source_item_hmac` is normally `HMAC(kms-subkey, "written:item:v1\\n…")`.
    RIS has no KMS, so this derives from a **different label** — never the
    same input under a different key, which could collide — so the value is
    deterministic, reproducible from this file, and provably not a real one.
    **The cost is real and is not hidden: a later genuine distillation of the
    same item computes the true hmac and stores a second row rather than
    recognising this one.** That is the price of the backfill and the reason
    the exact-join route is still worth having.
  * `encrypted_payload` holds the envelope in the clear under
    `ris_lab_plaintext_v1`, the same marker `0311` uses, so anything that
    tries to decrypt meets a key version it does not know and fails loudly.

`normalized_payload` needs no such apology: the function takes the projection
from the caller, so it is built here to the exact shape the account's existing
Spotify observations carry — `music-v03`, `catalog_item`, `public_catalog`.

    python3 tools/ris_backfill_vault.py 0313 <user-uuid> spotify
"""
from __future__ import annotations

import base64
import hashlib
import json
import pathlib
import subprocess
import sys
import uuid

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: **Which source, for which account, and nothing discovered.** A backfill
#: that chose for itself which accounts to write into would be a different and
#: much larger thing, so both are named on the command line and the source's
#: shape is looked up here.
#:
#: Every value below was *measured* from the rows ingestion already wrote for
#: that source — never chosen — so a backfilled row is the same shape as a
#: captured one rather than a second dialect. `action_type` equals `data_type`
#: for both of these sources. A `data_type` absent from a source's weights is
#: not written: the same positive-list discipline as the mention lanes, so a
#: type added later is skipped until somebody decides what it weighs.
SOURCES = {
    "spotify": {
        "weights": {"top_track": 0.78, "saved_track": 0.6, "top_artist": 0.55,
                    "followed_artist": 0.55, "saved_album": 0.55,
                    "playlist_item": 0.0},
    },
    "apple_music": {
        # **`recommendation` is 0.000 and that is a decision, not an unset
        # default**: Apple's suggestion is not the person's act, and the rule
        # is that no vocabulary is minted from these rows. Backfilling them
        # restores the evidence trail and deliberately moves no score.
        "weights": {"recently_played": 0.78, "playlist_item": 0.7,
                    "library_playlist": 0.6, "library_song": 0.48,
                    "recently_added": 0.55, "library_album": 0.55,
                    "library_artist": 0.45, "recommendation": 0.0},
    },
}

#: Shared by both music sources, and read from their own observations.
OBSERVATION_KIND = "catalog_item"
PAYLOAD_SCHEMA_VERSION = "music-v03"
PRIVACY_CLASS = "public_catalog"

RIS_KEY_VERSION = "ris_lab_plaintext_v1"
RIS_KMS_ARN = "arn:aws:kms:ris-lab:000000000000:key/no-kms-on-this-lane"

#: **A different label, deliberately.** Reusing `written:item:v1` under another
#: key would produce a value indistinguishable from a real hmac at a glance
#: and impossible to tell apart later. This one announces itself.
RIS_ITEM_LABEL = "written:item:ris-lab-backfill:v1"


def query(sql: str) -> list[dict]:
    """Run a read through the linked project and return its rows.

    **The format is asked for, not assumed, and that cost a run.** `text` is
    the CLI's default; it answered JSON anyway whenever stdout was not a
    terminal, so every call here worked until one was made from a real shell
    and came back as an ASCII table. `--output-format json` makes the answer
    the same wherever it is run.

    **And the answer is found by decoding, not by slicing.** The CLI prefixes
    its output with whatever warnings it has — the Docker "Mounts denied" one
    carries braces of its own — and the payload is an object without the flag
    and a bare array with it. So every `[` or `{` is offered to a real decoder
    and the first that yields rows wins.
    """
    result = subprocess.run(
        ["supabase", "db", "query", "--linked", "--output-format", "json", sql],
        capture_output=True, text=True, cwd=REPOSITORY)
    if result.returncode != 0:
        raise SystemExit(f"query failed: {result.stderr[:400]}")
    decoder = json.JSONDecoder()
    text = result.stdout
    for index, character in enumerate(text):
        if character not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except ValueError:
            continue
        # **Two shapes, because the flag changes it.** Without
        # `--output-format json` the CLI wraps the rows in an object beside a
        # `warning` key; with it the answer is the bare array. Accepting both
        # means this keeps working whichever the CLI decides to send.
        if isinstance(value, list):
            return value
        if isinstance(value, dict) and isinstance(value.get("rows"), list):
            return value["rows"]
    raise SystemExit(f"no json in the answer: {text[:400]}")


def quote(text) -> str:
    if text is None:
        return "null"
    return "'" + str(text).replace("'", "''") + "'"


def item_hmac(user_id: str, source: str, item_id: str) -> str:
    return hashlib.sha256(
        f"{RIS_ITEM_LABEL}\n{user_id}\n{source}\n{item_id}".encode()).hexdigest()


def row_id(row: dict) -> str:
    """Identity as `ris_build_items.py` and the linker compute it."""
    return hashlib.sha256("|".join([
        row["user_id"], row["source"], str(row.get("data_type")),
        str(row.get("item_id"))]).encode()).hexdigest()[:40]


def payload_for(row: dict) -> dict:
    """The projection, in the shape this source's observations already use."""
    extra = row.get("extra") or {}
    if isinstance(extra, str):
        extra = json.loads(extra)
    # **Pipe-joined, on both sources and in two fields.** Spotify's `creator`
    # is joined across every credit and Apple's `genres` across every genre;
    # the projection wants them as lists, and the first credit is what
    # `Ontology.musicSubject` stamps as the subject.
    credits = [c.strip() for c in str(row.get("creator") or "").split("|")
               if c.strip()]
    payload = {
        "title": str(row.get("name") or "")[:512],
        "record_kind": "music_item",
        "schema_version": PAYLOAD_SCHEMA_VERSION,
    }
    if credits:
        payload["credited_artists"] = credits
        payload["primary_performer"] = credits[0]
    # `detail` is the album only where it is not `key=value` plumbing — the
    # same reading `ris_build_items.py` applies, for the same reason. Apple's
    # `recommendation` rows carry `shelf=`, which is merchandising.
    detail = str(row.get("detail") or "").strip()
    if detail and "=" not in detail.split(" ", 1)[0]:
        payload["album"] = detail[:512]
    genres = [g.strip() for g in str(extra.get("genres") or "").split("|")
              if g.strip()]
    if genres:
        payload["genres"] = genres
    if extra.get("composer"):
        payload["composer"] = str(extra["composer"])[:512]
    if extra.get("isrc"):
        payload["isrc"] = str(extra["isrc"])
    if extra.get("released"):
        payload["release_date"] = str(extra["released"])[:10]
    if extra.get("rank") is not None:
        try:
            payload["rank"] = int(extra["rank"])
        except (TypeError, ValueError):
            pass
    return payload


def main() -> int:
    number, target_user, target_source = sys.argv[1], sys.argv[2], sys.argv[3]
    # **Only rows proved to have no observation are re-projected**, and the
    # proof comes from `ris_link_observations.py` rather than from a count.
    # The account may already hold rows for this source — Apple Music does —
    # and `ingest_source_records_v031` dedupes on `record_fingerprint`, which
    # a re-projection cannot reproduce: ingestion's fingerprint is taken over
    # its own envelope. So re-sending a row that already exists would store a
    # second copy rather than being ignored, and an `ambiguous` row already
    # has two or more observations and merely cannot be told which.
    only = None
    if len(sys.argv) > 4:
        only = set(json.loads(pathlib.Path(sys.argv[4]).read_text())
                   ["unlinked"]["unmatched"])
    if target_source not in SOURCES:
        raise SystemExit(f"no measured shape for {target_source}; add one to "
                         f"SOURCES from that source's own observations")
    weights = SOURCES[target_source]["weights"]
    rows = query(f"""
        select user_id::text, source, data_type, item_id, name, creator,
               detail, extra
          from public.summary_distilled_records
         where user_id = '{target_user}' and source = '{target_source}'
           and removed_at is null and coalesce(name,'') <> ''
           and coalesce(extra ->> 'markedRemoved','') <> '1'
         order by data_type, item_id
    """)

    records, skipped = [], {}
    for row in rows:
        data_type = str(row.get("data_type") or "")
        if data_type not in weights:
            skipped[data_type] = skipped.get(data_type, 0) + 1
            continue
        if only is not None and row_id(row) not in only:
            skipped["already_in_the_vault"] = skipped.get(
                "already_in_the_vault", 0) + 1
            continue
        payload = payload_for(row)
        if not payload.get("title"):
            skipped["no_title"] = skipped.get("no_title", 0) + 1
            continue
        envelope = {"record_source_code": target_source,
                    "data_type": data_type,
                    "provider_item_id": str(row["item_id"]),
                    "typed_payload": payload}
        records.append({
            "record_source_code": target_source,
            "data_type": data_type,
            "scope_key": f"{target_source}:{data_type}:{data_type}",
            "source_item_hmac": item_hmac(row["user_id"], target_source,
                                          str(row["item_id"])),
            # **Over the whole envelope, not the typed payload alone.** The
            # active-row uniqueness is `(user_id, source_code,
            # record_fingerprint)` — `data_type` is *not* in it — so a
            # fingerprint taken over the payload only collapses two records
            # that differ solely by type onto one raw row, and the run item
            # for the second then fails `guard_ingestion_run_item_v031` with
            # "raw evidence does not match its source identity". Measured
            # here: 7 artists this account both follows and tops, whose
            # payloads are byte-identical.
            #
            # `data_type` and `provider_item_id` are content; `observed_at`
            # and the run id are capture and stay out, which is the rule
            # `fingerprintContent` and `append_source_records` both apply.
            "record_fingerprint": hashlib.sha256(
                json.dumps({"data_type": data_type,
                            "provider_item_id": str(row["item_id"]),
                            "typed_payload": payload},
                           sort_keys=True,
                           ensure_ascii=False).encode()).hexdigest(),
            "encrypted_payload_b64": base64.b64encode(
                json.dumps(envelope, sort_keys=True,
                           ensure_ascii=False).encode()).decode(),
            # **`source_distillation` is not a choice.** A check constraint
            # ties the purpose to the source: `healthkit` must say
            # `fitness_connection`, a private calendar must say
            # `calendar_distillation`, and everything else must say this. The
            # column exists so a row records why it was allowed to be kept.
            "consent_purpose": "source_distillation",
            "retention_policy_version": "written-retention-v1",
            "normalized_payload": payload,
            "observation_kind": OBSERVATION_KIND,
            "payload_schema_version": PAYLOAD_SCHEMA_VERSION,
            "privacy_class": PRIVACY_CLASS,
            "observation_action_type": data_type,
            "observation_action_weight": weights[data_type],
        })

    scopes = sorted({r["scope_key"] for r in records})
    run_id = str(uuid.uuid5(uuid.NAMESPACE_URL,
                            f"written:ris-backfill:{target_user}:{target_source}"))

    out = [f"""-- {number} — the distillation the vault never received.
--
-- `{target_user[:8]}` holds {len(rows)} `{target_source}` rows in
-- `distilled_records` of which **{len(records)} reached no observation at
-- all** — not a deletion to respect, and not an ambiguity: rows the vault
-- simply never received. Which rows those are was *proved* by
-- `tools/ris_link_observations.py` and not inferred from a count, because an
-- account may legitimately hold rows for the same source and re-sending one
-- that already exists would store a second copy: `ingest_source_records_v031`
-- dedupes on `record_fingerprint`, and a re-projection cannot reproduce the
-- fingerprint ingestion took over its own envelope.
--
-- Rows the linker called *ambiguous* are excluded for the same reason: those
-- already have two or more observations and merely cannot be told which. Any
-- erasure found on the way is left alone.
--
-- **The rule is that this is ours to fix.** A change needing data re-projected
-- is our problem to solve server-side, and asking somebody to distil again is
-- a bug report about us.
--
-- **It goes through `ingest_source_records_v031`, not around it** — the one
-- entry point that opens the run, records the scopes, writes the raw rows,
-- promotes the observations, writes the run items and finalizes. A migration
-- that hand-wrote observations would be reimplementing that protocol beside it
-- and getting the guards wrong.
--
-- **Two values are marked rather than faked.** `source_item_hmac` is normally
-- `HMAC(kms-subkey, "written:item:v1\\n…")`; this lane has no KMS, so it
-- derives from a *different label* — never the same input under a different
-- key, which could collide — making it deterministic, reproducible from
-- `tools/ris_backfill_vault.py`, and provably not a real one. **The cost is
-- stated rather than hidden: a later genuine distillation of the same item
-- computes the true hmac and stores a second row rather than recognising
-- this one.** And `encrypted_payload` holds the envelope in the clear under
-- `ris_lab_plaintext_v1`, so anything attempting to decrypt meets a key
-- version it does not know and fails loudly.
--
-- `normalized_payload` needs no such caveat: the function takes the projection
-- from its caller, and this one is built to the exact shape the account that
-- *did* capture Spotify already carries — `music-v03`, `catalog_item`,
-- `public_catalog`, with the weights the server itself records.
--
-- Coverage is **`partial`**, never `complete`: only `complete` licenses
-- expiring an item that went missing, and a re-projection of a capped read is
-- not a claim to have seen everything.

do $$
declare
  receipt jsonb;
begin
  -- A replay has no such account, so there is nothing to re-project and
  -- nothing to assert. Raising here would make the migration unreplayable.
  if not exists (select 1 from auth.users where id = {quote(target_user)}::uuid) then
    raise notice '{number}: no such account here; nothing to re-project';
    return;
  end if;
  -- **No whole-source refusal.** The account may legitimately already hold
  -- rows for this source; what matters is that every row below was proved to
  -- have none, which the generator did against the link report. Refusing the
  -- whole source would make this migration inapplicable to exactly the case
  -- it was extended for.

  receipt := semantic_private.ingest_source_records_v031(
    {quote(target_user)}::uuid,
    {quote(run_id)}::uuid,
    {quote(target_source)},
    'ris-backfill-v1',
    {quote(hashlib.sha256(run_id.encode()).hexdigest())},
    {quote(RIS_KEY_VERSION)},
    {quote(base64.b64encode(b'ris-lab: no kms on this lane').decode())},
    {quote(RIS_KMS_ARN)},
    {quote(json.dumps([
        {"scope_key": s, "source_code": target_source,
         "data_type": s.split(":")[1], "action_type": s.split(":")[2],
         # **`full_snapshot` and `partial`, copied from the scopes the
         # connector itself wrote.** `partial` is the load-bearing one: only
         # `complete` licenses expiring an item that went missing, and every
         # read behind these rows was capped, so claiming completeness would
         # be inferring absence from omission.
         "snapshot_mode": "full_snapshot", "completeness": "partial"}
        for s in scopes]))}::jsonb,
    $records${json.dumps(records, ensure_ascii=False)}$records$::jsonb,
    true,
    {quote(json.dumps({'coverage': 'partial'}))}::jsonb);

  raise notice '{number}: %', receipt;
end;
$$;
"""]

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_distillation_the_vault_never_received.sql")
    path.write_text("\n".join(out) + "\n")
    print(json.dumps({"rows_read": len(rows), "records": len(records),
                      "scopes": scopes, "skipped": skipped,
                      "run_id": run_id, "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
