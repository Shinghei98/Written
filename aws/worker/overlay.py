"""The candidate overlay's eight jobs.

`0203` created the tables and `0205` gave them tenancy and idempotency; nothing
wrote to them. These are the writers.

## The lane these run in

`compiled_semantic_contract_v1.json` declares `initial_mode: exact_only` and
`qwen_overlay: disabled_until_all_deploy_gates_pass`, and the specification says
what that leaves: *"resolve stable identifiers and exact aliases before any model
call."* **The exact lane is resolution, not extraction** — so seven of these
eight run today, against the 73,126 mentions the legacy resolver has already
mined, with no model, no gateway and no network call of any kind.

`extract_mentions` is the exception and is the model lane by definition: the
workbook keys its idempotency on `model_version+prompt_version+grammar_version`.
It ships declining, which is a complete implementation of what it must do while
the overlay is off — not a stub. Registering a job type whose handler is absent
is worse than not registering it, because the job is claimed, found handler-less
and marked `dead` with no retry.

## What they share

- **Bounded work.** Every handler caps what one invocation touches. EventBridge
  drains the queue every two minutes and a Lambda has fifteen; a job that tried
  to resolve one account's 73,126 mentions in a single claim would time out and
  be retried from the start, forever.
- **Idempotent by constraint, not by care.** `0205`'s
  `mention_resolutions_one_per_route`, `review_items_one_card_per_epoch` and the
  partial unique indexes on `user_term_candidates` mean a re-run inserts nothing
  new. Every insert here is `on conflict do nothing` and means it.
- **Counts in receipts, never text.** `worker_job_result_is_safe_v03` refuses
  anything else, and a title in a receipt would be a title in a log.
- **The contract decides, not these constants.** Roles, predicates, families and
  the overlay switch are read from `written_ontology.semantic_contract`.
"""

from __future__ import annotations

import json
from typing import Any

from resolve import SELECT_GENRE_CONCEPTS
from written_ontology.semantic_contract import load as load_contract

#: One invocation's ceiling. Chosen so the slowest of these — resolution, which
#: joins each mention against the published label set — stays far inside a
#: fifteen-minute Lambda on the largest account in the database, and so that a
#: partial pass leaves a queue that the next tick continues rather than repeats.
RESOLVE_BATCH = 2000
CANDIDATE_BATCH = 5000
REVIEW_PAGE = 24

#: How much extraction one job may do. The wire maximum stays two items per
#: model call — raising it is a contract change — so throughput comes from
#: looping calls inside the job instead: up to this many calls, stopping early
#: when the time remaining could not fit another round trip (the lane's own
#: timeout is 25 s; the Lambda's is 300). Measured before the loop existed:
#: one 2-item call per job, ~15 items/hour, a 1,846-row backlog five days
#: deep. Each batch commits as it lands, so a deferral mid-loop keeps every
#: batch already written.
EXTRACT_MAX_CALLS = 20
EXTRACT_BUDGET_S = 210.0
#: **The reserve must exceed the lane's own timeout**, or the loop starts a
#: call it cannot wait out — the Lambda dies mid-inference, and a killed worker
#: defers nothing. The lane states 75 s, so this is that plus a margin for the
#: write that follows.
EXTRACT_CALL_RESERVE_S = 85.0

#: The route these jobs write. A route is *how* a resolution was reached, and it
#: is recorded per row because feedback is attributed to it: `aggregate_feedback`
#: cannot say which route is producing bad terms if every row claims the same
#: one. `exact_label` is the only route the exact lane has.
EXACT_ROUTE = "exact_label"

#: Everything the exact lane can claim about somebody. A resolved mention says a
#: term appeared in their library, which is an affinity and is not a claim that
#: they *do* the thing — `0200` put participation and spectating behind evidence
#: that says so, and a label match says neither.
EXACT_PREDICATE = "affinity_to"

#: The bar `score.py` uses for an assertion. Reused rather than reinvented: a
#: candidate below it is real evidence that has not earned a claim, which is
#: what `secondary` means.
ELIGIBILITY = 0.35

#: `strength` saturates as `w/(w+6)` in the scorer, and the same curve is used
#: here so a candidate's score and the assertion it may become are on one scale.
#: A hard cap would tie every strong concept at 1.0.
SATURATION = 6.0


def _published_version(cursor) -> str | None:
    cursor.execute("select id from ontology.versions where status = 'published'")
    row = cursor.fetchone()
    return row["id"] if row else None


# ---------------------------------------------------------------------------
# 1. extract_mentions — the model lane
# ---------------------------------------------------------------------------

def extract_mentions(job) -> dict[str, Any]:
    """Propose mentions with the model. Declines while the overlay is off.

    **This is the whole handler and it is not a placeholder.** The contract says
    the overlay is disabled until every deploy gate passes, and the honest
    behaviour of a model job in that state is to decline and say so. The
    alternative — not registering the job type until the gateway exists — means
    the type cannot be enqueued, and the day the overlay is enabled becomes the
    day a migration, a handler and a gateway all ship together.

    The switch is read from the compiled contract rather than an environment
    variable, so turning the lane on is a contract change a deploy validator
    compares against what it attested to.
    """
    contract = load_contract()
    mode = contract.model_lane_mode

    # **Branch on the mode, not on a boolean.** The old test asked whether the
    # contract string contained "disabled", which fails open: `evaluation`
    # contains no such word and would have fallen straight through to the
    # `NotImplementedError` below. The four modes are exhaustive and unknown
    # values already raised in `model_lane_mode`, so there is no `else` that
    # silently proceeds.
    if mode == "off":
        return {
            "status": "no_op",
            "abstained": True,
            "item_count": 0,
        }

    # `evaluation` and `shadow` both call the model; they differ in what may be
    # written, which is enforced where the writes happen rather than here — a
    # handler that decided its own permissions would be a second copy of the
    # rule. What is common to both is that neither can run without a gateway.
    return _propose_with_model(job, mode)


#: What a mention proposed by the model is called, and the only value
#: `guard_model_mention_lineage` accepts alongside an invocation item.
_MODEL_METHOD = "model_proposed"
_INFERRED_METHOD = "model_inferred"

#: **The method travels with the row.** A mention the model *read* and one it
#: *asserted* are both its output and are stored alike, but they are not the
#: same claim: one can be checked against a source string and one cannot, and
#: a dictionary that forgot which was which could not be audited afterwards.
#: `0286` admits the fourth value.
#:
#: The model lane writes a mention exactly as the exact lane does, except for
#: the two columns that say where it came from. Everything else — the
#: conflict key, the mining flags, the locale — is deliberately identical, so a
#: model mention and a projection mention are the same kind of row about the
#: same observation rather than a parallel vocabulary.
_INSERT_MODEL_MENTION = """
insert into semantic_private.observation_mentions (
  observation_id, user_id, mention_text, normalized_text, mention_role,
  locale, type_hint, source_field, extraction_method, confidence,
  safe_for_global_mining, safe_for_external_resolution, evidence_weight,
  model_invocation_item_id)
values (
  %(observation_id)s, %(user_id)s, %(mention_text)s, %(normalized_text)s,
  %(mention_role)s, 'und', %(type_hint)s, %(source_field)s, %(extraction_method)s,
  %(confidence)s, false, false, %(evidence_weight)s,
  %(model_invocation_item_id)s)
on conflict (observation_id, normalized_text, mention_role,
             coalesce(source_field, ''), extraction_method) do nothing
"""


class InferenceDeferred(Exception):
    """The work is accepted and unfinished; come back rather than fail.

    **Not a handler error and not a receipt.** `in_flight` is not one of the nine
    status words `worker_job_result_is_safe_v03` permits, so it cannot be
    persisted as a result — and raising an ordinary exception would record
    `handler_error`, spend a failure attempt, and eventually mark the job dead
    while the inference it is waiting for is still running perfectly well.
    """

    def __init__(self, item_count: int) -> None:
        super().__init__("the endpoint accepted the work and has not answered")
        self.item_count = item_count


def _propose_with_model(job, mode: str) -> dict[str, Any]:
    """The bridge: ask the model under one identity, write under another.

    **The two halves cannot be collapsed and the schema is what says so.**
    `0241` refuses `semantic_worker` the right to record a model call; `0243`
    refuses it the right to read invocation items. So this handler hands the
    work to `ModelLane`, which holds the other credential, and receives back a
    value: an invocation id and one lineage row per requested item. It then
    writes mentions naming those items — which `guard_model_mention_lineage`
    permits only where the item exists, succeeded, and belongs to an invocation
    whose lane may say something about a person.

    A worker that could forge that link would make the guard decorative. It
    cannot: it has no insert on `model_invocation_items` at all.
    """
    user_id = job.payload["user_id"]
    # **Nothing is read from the payload but `user_id`.** `0208` requires this
    # job to carry *exactly* `user_id`, `grammar_version` and `prompt_version`,
    # and `worker_json_has_exact_keys_v03` refuses anything else at enqueue —
    # so `request_id`, `resume`, `limit` and `source_profile` could never have
    # travelled there. Reading them was writing against a contract the database
    # would not accept a job under.
    #
    # The request id is derived from the job instead, which is better than a
    # payload key: it is stable across retries by construction rather than by
    # whoever enqueued remembering to reuse it.
    request_id = _request_id(job)

    import psycopg  # noqa: PLC0415
    from psycopg.rows import dict_row  # noqa: PLC0415

    from handler import VAULT_KEY_ARN, _kms, database_url  # noqa: PLC0415

    # **The deterministic connection, and only ever this one here.** The model
    # lane opens its own with the other credential; nothing in this function
    # touches it, and nothing in that one writes a mention.
    connection = psycopg.connect(database_url(), row_factory=dict_row,
                                 prepare_threshold=None)
    with connection:
        return _propose_and_write(connection, job, mode, user_id, request_id,
                                  _kms, VAULT_KEY_ARN)


def _propose_and_write(connection, job, mode, user_id, request_id,
                       kms, vault_key_arn) -> dict[str, Any]:
    from model_lane import InFlight, LaneUnavailable, ModelLane  # noqa: PLC0415

    # **Evaluation never touches a person's rows.** `0239` raises on an
    # evaluation invocation that names a user, an observation or retained source
    # text — three separate refusals — so the previous shape was not merely
    # over-permissive, it was a call the database would reject outright after
    # the model had already been paid for. Declining to *write* the mention was
    # the wrong place to stop: the fixture rule is about what may be read.
    #
    # There is no fixture corpus yet, so this declines rather than inventing
    # one. An evaluation lane that quietly ran against real accounts would be
    # the exact failure the mode exists to prevent.
    if mode == "evaluation":
        # **Routed to the corpus, and it cannot fall back.** `_evaluation_items`
        # reads a versioned synthetic file and nothing else; there is no branch
        # from here to a real account, which is what `0239`'s three refusals ask
        # for and what an early return could only approximate by doing nothing.
        return _evaluate_against_fixtures(job, request_id)

    # **File evidence before asking for it.** Nothing in production wrote
    # `source_text_evidence`, so the lane had nothing to read and would have run
    # forever finding nothing. The text the model needs is the title, which the
    # sanitised projection deliberately excludes — so it comes from the vault,
    # and filing it is what gives `guard_model_mention_lineage` something to
    # hang a mention on and `forget_distillation` something to redact.
    _file_evidence(connection, user_id, kms, vault_key_arn)

    # **The loop, not the batch, is the unit of work now.** One 2-item call per
    # job was the shakedown gait; the wire maximum has not moved, the job just
    # makes several calls. Each batch's request id is derived from the evidence
    # ids themselves, so retry stability no longer leans on the job identity:
    # whichever job next selects the same still-pending rows — this one on a
    # deferral retry, or a freshly armed one — computes the same id and
    # collects the same inference instead of paying for a second.
    import hashlib  # noqa: PLC0415
    import time  # noqa: PLC0415

    # Constructed on first use: a queue with nothing to ask must not touch the
    # lane at all — an empty call would record an invocation that asked nothing.
    lane = None
    deadline = time.monotonic() + EXTRACT_BUDGET_S
    calls = 0
    total_items = 0
    total_written = 0

    while calls < EXTRACT_MAX_CALLS \
            and time.monotonic() + EXTRACT_CALL_RESERVE_S < deadline:
        items = _items_for(connection, user_id, job.payload, kms, vault_key_arn)
        if not items:
            break
        if lane is None:
            lane = ModelLane()

        batch_request_id = "req_" + hashlib.sha256(
            (user_id + ":" + ",".join(sorted(
                str(item["source_text_evidence_id"]) for item in items))
             ).encode()).hexdigest()[:40]

        try:
            proposed = lane.propose(
                user_id=user_id,
                items=[_wire_item(item) for item in items],
                request_id=batch_request_id,
                # **From the evidence, not from the payload.** The source
                # profile is a property of the rows being asked about; a job
                # key would let the enqueuer describe somebody else's data.
                # **Refused rather than defaulted.** `"youtube"` as a fallback
                # was the worst possible default: the one profile whose data
                # may not be here at all.
                source_profile=_one_profile(items))
        except InFlight:
            # The endpoint accepted this batch and has not answered. With
            # nothing yet banked the whole job defers, exactly as before; with
            # earlier batches committed it stops here instead — those batches
            # are durable, and the in-flight one is collected by whichever job
            # next selects the same rows, because the id is derived from them.
            # **A queue state, not a receipt.** `in_flight` is not one of the
            # nine permitted status words, so it can never be persisted as a
            # result; the dedicated exception defers without spending a
            # failure attempt and without writing `last_error`.
            print(json.dumps({"extract_mentions": "in_flight",
                              "items": len(items), "calls": calls}))
            if calls == 0:
                raise InferenceDeferred(len(items)) from None
            break
        except LaneUnavailable as unavailable:
            # **Deferred, never failed** — an open breaker cooling off and a
            # capacity drought are both transient, and a RuntimeError here once
            # cost five attempts and a permanently wedged user (`0210`). Same
            # partial-progress rule as above: an empty job defers, a job with
            # banked batches keeps them.
            print(json.dumps({"extract_mentions": "lane_unavailable_deferred",
                              "items": len(items), "calls": calls}))
            if calls == 0:
                raise InferenceDeferred(len(items)) from unavailable
            break

        # Evaluation returned above without reading anything, so anything
        # reaching here is `shadow` or `active` — the two lanes `0237` permits
        # a user mention from. One rule, in one place.
        written = _write_model_mentions(connection, user_id, items, proposed)
        # **Committed per batch, deliberately.** The lane records invocation
        # items on its own credential's connection the moment a call succeeds;
        # if this connection rolled a later deferral back over an earlier
        # batch's mentions, those rows would be unreachable forever — the
        # evidence is marked asked-about and never re-selected, and the
        # mentions it paid for would not exist.
        connection.commit()

        # **Bounded and in the permitted vocabulary.** `ok` is not a status
        # word; `invocation_id` is not a permitted id key — the invocation
        # ledger already holds those facts, and a receipt duplicating them is
        # a second copy that can disagree with the first.
        print(json.dumps({"extract_mentions": {
            "invocation_id": proposed["invocation_id"],
            "outcomes": [row["outcome"] for row in proposed["lineage"]]}}))
        calls += 1
        total_items += len(items)
        total_written += written

    if total_items == 0:
        # **Nothing to ask about is not a failure.** An account whose evidence
        # has not been captured yet, or whose text has been erased, produces no
        # request — and an empty call would record an invocation that asked
        # nothing.
        print(json.dumps({"extract_mentions": "no_evidence"}))
        return {"status": "no_op", "abstained": True, "item_count": 0}

    return {
        "status": "succeeded",
        "abstained": False,
        "item_count": total_items,
        "created_count": total_written,
    }


#: The corpus, beside the contracts it is evaluated against. Versioned in the
#: filename, so a changed corpus is a different corpus rather than the same one
#: with different contents — a score measured against one must never be silently
#: compared with a score measured against another.
EVALUATION_CORPUS = "evaluation_corpus_v1"


def _evaluation_items(limit: int) -> list[dict[str, Any]]:
    """Synthetic items, carrying no identifier of any kind.

    Every user-linked field is **absent rather than null-by-accident**: the items
    have no `observation_id` and no `source_text_evidence_id`, so
    `model_lane._record` writes nulls because there is nothing to write, not
    because something remembered to blank them.
    """
    import pathlib  # noqa: PLC0415

    here = pathlib.Path(__file__).resolve()
    # The repository tree, then the Lambda bundle root — `build.sh` preserves
    # `semantic/fixtures/...` under it, so one relative path serves both and the
    # reader never learns a second layout.
    for root in (here.parents[2], pathlib.Path("/var/task")):
        path = root / "semantic" / "fixtures" / "mention_extract" / f"{EVALUATION_CORPUS}.json"
        if path.is_file():
            corpus = json.loads(path.read_text())
            break
    else:
        raise RuntimeError(f"the evaluation corpus {EVALUATION_CORPUS} is not packaged")

    if corpus.get("corpus_version") != EVALUATION_CORPUS:
        raise RuntimeError(
            f"corpus says {corpus.get('corpus_version')!r}, expected {EVALUATION_CORPUS!r}")

    return [
        {
            "item_index": index,
            "fields": {"title": entry["title"]},
            # A profile is still required — the model is asked the same question
            # it would be asked in shadow, or the evaluation measures a different
            # question.
            "source_profile": "music_catalog",
            "logical_extraction_key": f"fixture:{EVALUATION_CORPUS}:{entry['id']}",
        }
        for index, entry in enumerate(corpus["items"][:limit])
    ]


def _evaluate_against_fixtures(job, request_id: str) -> dict[str, Any]:
    """Ask the model the real question against invented text.

    **No user, no observation, no evidence, and no mention written.** `0239`
    refuses an evaluation invocation that names a person and `0237` refuses a
    user mention from any lane but shadow or active, so the only thing this
    produces is an invocation and its items — which is the whole point: an
    evaluation that wrote nothing *and called nothing* proved nothing.
    """
    from model_lane import InFlight, LaneUnavailable, ModelLane  # noqa: PLC0415

    contract = load_contract()
    items = _evaluation_items(contract.max_items_wire)

    try:
        proposed = ModelLane().propose(
            # **None, not a placeholder account.** The lane passes it straight to
            # `record_model_invocation`, and a fabricated uuid would be a person
            # who does not exist rather than an absence.
            user_id=None,
            items=items,
            request_id=request_id,
            source_profile=_one_profile(items))
    except InFlight:
        print(json.dumps({"extract_mentions": "evaluation_in_flight"}))
        raise InferenceDeferred(len(items)) from None
    except LaneUnavailable as unavailable:
        # **Deferred, not failed.** Unavailability includes an open breaker
        # cooling off after a wake — transient by definition — and a failed job
        # would either dead-letter or complete, and completing is what consumed
        # a release idempotency key on an invocation that never invoked.
        print(json.dumps({"extract_mentions": "lane_unavailable_deferred"}))
        raise InferenceDeferred(len(items)) from unavailable

    print(json.dumps({"extract_mentions": {
        "evaluation": EVALUATION_CORPUS,
        "invocation_id": proposed["invocation_id"],
        "outcomes": [row["outcome"] for row in proposed["lineage"]]}}))
    return {"status": "succeeded", "abstained": False,
            "item_count": len(items), "created_count": 0}


def _one_profile(items: list[dict]) -> str:
    """The batch's single profile, or a refusal.

    Every item must agree. A batch that disagreed would be described to the
    model by whichever row happened to be first, and the profile decides which
    predicates the source is allowed to produce.
    """
    profiles = {item.get("source_profile") for item in items}
    if len(profiles) != 1 or None in profiles:
        raise RuntimeError(
            f"a batch must carry exactly one permitted profile, got {sorted(str(p) for p in profiles)}")
    return profiles.pop()


def _request_id(job) -> str:
    """Stable for the job, because a retry must not become a second inference.

    The transport submits under this id and the ticket store is keyed on it, so
    a job that is retried collects the answer it already paid for. A fresh id
    per attempt would restore exactly the duplicate-submission the derived id
    was introduced to remove.
    """
    import hashlib  # noqa: PLC0415

    seed = f"{job.payload.get('user_id')}:{job.payload.get('job_id') or job.id}"
    return "req_" + hashlib.sha256(seed.encode()).hexdigest()[:40]


#: Vault rows whose text has not been filed as evidence yet. Read through the
#: current-state table rather than `raw_source_records`, which is the same rule
#: as reading through the `summary_*` views: nothing supersedes a prior
#: revision, so the raw table holds every version and only this one says which
#: is current.
SELECT_UNFILED_VAULT_ROWS = """
select c.current_raw_source_record_id as raw_id,
       c.current_observation_id as observation_id,
       r.encrypted_payload,
       r.encryption_key_version
  from semantic_private.current_source_items c
  join semantic_private.raw_source_records r
    on r.id = c.current_raw_source_record_id
 where c.user_id = %(user_id)s
   -- **An allowlist, passed in, so an unknown source is denied by absence.**
   -- The list is `MODEL_INPUT_PROFILES`, which is also where each source's
   -- contract profile lives — one table, because permission and profile are one
   -- decision and two tables would eventually disagree.
   and c.source_code = any(%(allowed)s)
   and c.current_observation_id is not null
   and r.encrypted_payload is not null
   and not exists (
     select 1 from semantic_private.source_text_evidence e
      where e.observation_id = c.current_observation_id
        and e.refresh_status <> 'deleted'
   )
 limit %(limit)s
"""

INSERT_EVIDENCE = """
insert into semantic_private.source_text_evidence
  (user_id, observation_id, encrypted_text, encryption_key_version,
   retention_class, expires_at)
values (%(user_id)s, %(observation_id)s, %(encrypted_text)s,
        %(encryption_key_version)s, %(retention_class)s, %(expires_at)s)
on conflict do nothing
"""


def _file_evidence(connection, user_id: str, kms, vault_key_arn,
                   limit: int = 200) -> int:
    """Copy the text the model will be asked about out of the vault.

    **Encrypted with the account's own data key, which needs no new
    permission.** The worker already unwraps that key to read raw records, and a
    plaintext DEK encrypts as well as it decrypts — so the rule that the
    internet-facing ingestor holds encrypt-only and cannot read the vault back
    is untouched. What is filed is the title and nothing else; the fields the
    request schema does not name could not travel to the model anyway.
    """
    import datetime  # noqa: PLC0415
    import os  # noqa: PLC0415

    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: PLC0415

    from observations import decrypt_payload  # noqa: PLC0415

    with connection.cursor() as cursor:
        cursor.execute(SELECT_UNFILED_VAULT_ROWS,
                       {"user_id": user_id, "limit": limit,
                        "allowed": list(MODEL_INPUT_PROFILES)})
        rows = [dict(row) for row in cursor.fetchall()]
    if not rows:
        return 0

    keys: dict[str, bytes] = {}
    filed = 0
    for row in rows:
        version = row["encryption_key_version"]
        if version not in keys:
            with connection.cursor() as cursor:
                cursor.execute(
                    "select wrapped_dek from semantic_private.user_encryption_keys"
                    " where user_id = %s and key_version = %s",
                    (user_id, version))
                key_row = cursor.fetchone()
            if key_row is None:
                # Crypto erasure is a supported state; an account that has
                # exercised it must not make every later job fail.
                continue
            # **The context is not optional.** `aws/ingestion/index.mjs` wraps
            # the key under `{user_id}`, and KMS refuses a decrypt whose context
            # does not match — so omitting it fails every unwrap, for every
            # account, with an error about the key rather than about the call.
            keys[version] = kms.decrypt(
                CiphertextBlob=bytes(key_row["wrapped_dek"]),
                KeyId=vault_key_arn,
                EncryptionContext={"user_id": user_id})["Plaintext"]

        try:
            envelope = decrypt_payload(keys[version],
                                       bytes(row["encrypted_payload"]))
        except Exception:  # noqa: BLE001 - unreadable is skipped, never guessed
            continue
        title = _title_of(envelope)
        if not title:
            continue

        iv = os.urandom(12)
        ciphertext = iv + AESGCM(keys[version]).encrypt(
            iv, json.dumps({"text": title}).encode(), None)
        with connection.cursor() as cursor:
            cursor.execute(INSERT_EVIDENCE, {
                "user_id": user_id,
                "observation_id": row["observation_id"],
                "encrypted_text": ciphertext,
                "encryption_key_version": version,
                "retention_class": "provider_catalog_text",
                # The same thirty days III.E.4 requires of a title, applied to
                # every source rather than only the one that demands it.
                "expires_at": datetime.datetime.now(datetime.timezone.utc)
                              + datetime.timedelta(days=30),
            })
        filed += 1
    connection.commit()
    return filed


#: **The sources whose text may reach a model, and the contract profile each
#: maps to. One table, because they are one decision.**
#:
#: A denylist naming Spotify and YouTube was the wrong shape: the failure mode of
#: a deny-list is silence, and a source added next month would be permitted by
#: nobody having thought about it. Here an unknown source is absent, and absent
#: means denied — which is also why the profile lives in the same mapping rather
#: than being derived from the source code. `music_library` is not a profile the
#: request schema knows; passing a raw source code through would have been
#: refused at the wire, or worse, accepted as a profile that means something else.
#:
#: **Five sources may feed a model; Spotify may not.** Apple Music, Apple
#: Podcasts and the device library carry no term restricting downstream use.
#: YouTube joined 2026-08-20 under the owner's interpretation of record — the
#: additional terms permit integrative app function, and the three-lane
#: contract makes it a first-class term-discovery lane (its request profile
#: existed in `mention_extract_request_v1` from the start). Spotify stays out:
#: IV.2.1.a, and IV.2.5 closes the consent route. Calendar is licensed and
#: still absent HERE — its titles reach the scorer through the classifier
#: Lambda — pending the Events-lane work the same contract defines. HealthKit
#: has no text at all. Adding a source is a decision to make in this table.
MODEL_INPUT_PROFILES = {
    "apple_music": "apple_music",
    "music_library": "music_catalog",
    "apple_podcasts": "podcast",
    "podcast": "podcast",
    "youtube": "youtube",
}


def model_input_profile(source_code: str | None) -> str | None:
    """The contract profile for a source, or None if it may not be sent.

    None is the answer for an unknown source as well as a prohibited one, and
    that is deliberate: the two are the same fact from here, which is that
    nothing has decided this source may feed a model.
    """
    if not source_code:
        return None
    return MODEL_INPUT_PROFILES.get(source_code)


#: Where a title actually lives. **Both envelope wire forms**, because
#: `schema_version` is `written-source-envelope-v2`, v1 rows exist forever and a
#: reader must handle both — v1 put the payload under an enum's associated value
#: and v2 puts it under `payload`. Reading only the top level found a title in
#: neither, so every row was skipped and the lane reported an empty account.
_TITLE_PATHS = (
    # v2 wraps the case's value under `value`.
    ("typed_payload", "value", "title"),
    ("typed_payload", "value", "name"),
    # v1 put the associated value under the case name, Swift's `_0`. The case
    # itself varies by data type, so the case key is walked rather than named —
    # bounded to one level, which is not a recursive search.
    ("typed_payload", "name"),
    ("typed_payload", "title"),
)

#: v1's shape is `typed_payload.<case>._0.title`, and `<case>` is the data type.
#: Handled by walking one level of case keys rather than enumerating every data
#: type, which would be a list to forget to extend.
_V1_INNER = ("_0",)


def _title_of(envelope: Any) -> str | None:
    """The one field the model is asked about, wherever the envelope keeps it.

    Named paths rather than a recursive search: the request schema is an
    allowlist, and a walk that returned the first string it found would file
    whatever happened to be nearest — an identifier, a URL, somebody's note.
    """
    if not isinstance(envelope, dict):
        return None

    for path in _TITLE_PATHS:
        found = _at(envelope, path)
        if found:
            return found

    # v1: `typed_payload.<case>._0.{title,name}`. The case key is whatever the
    # data type was called, so one level is walked — and only into `_0`, never
    # into arbitrary keys, so this cannot return the first string it happens to
    # meet.
    typed = envelope.get("typed_payload")
    if isinstance(typed, dict):
        for case in typed.values():
            if not isinstance(case, dict):
                continue
            for inner in _V1_INNER:
                for field in ("title", "name"):
                    found = _at(case, (inner, field))
                    if found:
                        return found
    return None


def _at(node: Any, path: tuple[str, ...]) -> str | None:
    """One named traversal, returning a non-empty string or nothing."""
    for step in path:
        if not isinstance(node, dict):
            return None
        node = node.get(step)
    return node.strip() if isinstance(node, str) and node.strip() else None


SELECT_EVIDENCE_ITEMS = """
select e.id as source_text_evidence_id,
       e.observation_id,
       e.user_id,
       o.source_code,
       o.action_type,
       o.data_type,
       e.encrypted_text,
       e.encryption_key_version
  from semantic_private.source_text_evidence e
  join semantic_private.observations o on o.id = e.observation_id
 where e.user_id = %(user_id)s
   and e.refresh_status = 'current'
   and o.lifecycle_state = 'active'
   -- **The allowlist again, because this is a second boundary.** Evidence filed
   -- before a source was removed from the list must not become sendable, and a
   -- row inserted by hand must not be selectable either.
   and o.source_code = any(%(allowed)s)
   -- **Never twice.** Without this the same two rows were reselected on every
   -- run: the batch never advanced, and a converged account looked identical to
   -- one that had never started.
   and not exists (
     select 1 from semantic_private.model_invocation_items i
      where i.source_text_evidence_id = e.id
   )
 -- Deterministic, so the armer and the handler see the same ordered set. Ties
 -- on `fetched_at` are real — a batch inserted in one statement shares the
 -- transaction timestamp — so `id` breaks them. (`created_at` here was the
 -- first shadow run's UndefinedColumn, 2026-08-20: the fixture path never
 -- executes this query, so the wrong name shipped dark through the whole
 -- evaluation phase — the ships-dark defect this repo keeps paying for.)
 --
 -- **The discovery lane goes first.** The Qwen lane exists for global term
 -- discovery, and YouTube is where the unknown nouns live — a strict FIFO put
 -- one account's 524 YouTube rows behind ~1,300 music rows, days away at the
 -- measured rate. Order is not part of any receipt, so this is a product
 -- decision, not a contract change; music evidence resumes when YouTube is
 -- drained.
 order by (o.source_code = 'youtube') desc, e.fetched_at, e.id
 limit %(limit)s
"""


def _items_for(connection, user_id: str, payload: dict[str, Any],
               kms, vault_key_arn) -> list[dict]:
    """The evidence this call will ask about, bounded by the contract.

    Bounded here rather than by the gateway, because a request the gateway has
    to refuse for size is a call that should not have been built. The cap is the
    contract's own wire maximum — two — which is why the batch is small and why
    the job is enqueued per batch rather than per account.
    """
    # The contract's own wire maximum. Not a payload key: `0208` forbids one,
    # and a caller-chosen batch size is a caller-chosen cost.
    contract = load_contract()
    limit = contract.max_items_wire
    with connection.cursor() as cursor:
        cursor.execute(SELECT_EVIDENCE_ITEMS,
                       {"user_id": user_id, "limit": limit,
                        "allowed": list(MODEL_INPUT_PROFILES)})
        rows = [dict(row) for row in cursor.fetchall()]

    # **Decrypted here, in the identity that holds `Decrypt`.** The plaintext
    # exists in this process and in the gateway's request; it never reaches
    # `model_invocation_items`, which has no text column, and it is not written
    # anywhere by this handler.
    # **One profile per batch.** A request carries a single `source_profile`, so
    # a batch spanning two sources would describe every item by the first row's
    # rules. The batch is narrowed to the first source rather than refused: the
    # remainder is still outstanding and the next job takes it.
    if rows:
        first = rows[0].get("source_code")
        rows = [row for row in rows if row.get("source_code") == first]

    # **Indices are assigned after the skips, not before them.** Enumerating the
    # selected rows and skipping the unreadable ones left holes — `item_index`
    # 0 and 2 with no 1 — which the request schema refuses outright, so one
    # unreadable row would have failed the whole batch.
    items = []
    for row in rows:
        text = _plaintext(connection, kms, row, vault_key_arn)
        if not text:
            _mark_unreadable(connection, row)
            continue
        items.append({
            "item_index": len(items),
            "fields": {"title": text[:256]},
            "observation_id": row["observation_id"],
            "source_text_evidence_id": row["source_text_evidence_id"],
            # **Stable across retries**, so a second attempt at the same work is
            # a second attempt rather than a second logical extraction — which
            # is what `one standing success per logical extraction` counts.
            "logical_extraction_key":
                f"model:{row['source_text_evidence_id']}",
            # The contract's profile, never the raw source code — `music_library`
            # is not a profile the request schema knows.
            "source_profile": model_input_profile(row.get("source_code")),
            # Contract 8.1: the exact observed action travels with the item, so
            # the model reads "liked_video" as a like and never as a watch.
            "source_action": row.get("action_type"),
        })
    return items


def _mark_unreadable(connection, row) -> None:
    """Retire evidence nothing can read, so it stops being outstanding.

    **Otherwise it blocks the account for ever.** The batch is selected by
    anti-join against invocation items, and an unreadable row never earns one —
    so it is picked again on every run, fills the two-item batch, and no later
    evidence is ever reached. The lane would report work outstanding and make no
    progress, indefinitely.

    Retired the way everything else here is: redacted, not deleted. `deleted` is
    the state the payload-location check and the lineage guard already
    understand, and the row keeps its identity.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            "update semantic_private.source_text_evidence"
            "   set encrypted_text = null, refresh_status = 'deleted',"
            "       deleted_at = now()"
            " where id = %s and refresh_status <> 'deleted'",
            (row["source_text_evidence_id"],))
    connection.commit()


def _plaintext(connection, kms, row, vault_key_arn) -> str | None:
    """One evidence row, decrypted, or None if it cannot be read.

    A row whose key is gone is skipped rather than raising: crypto erasure is a
    supported state, and an account that has exercised it must not make every
    later job fail.
    """
    from observations import decrypt_payload  # noqa: PLC0415

    with connection.cursor() as cursor:
        cursor.execute(
            "select wrapped_dek from semantic_private.user_encryption_keys "
            "where user_id = %s and key_version = %s",
            (row["user_id"], row["encryption_key_version"]))
        key_row = cursor.fetchone()
    if key_row is None:
        return None
    dek = kms.decrypt(CiphertextBlob=bytes(key_row["wrapped_dek"]),
                      KeyId=vault_key_arn,
                      EncryptionContext={"user_id": str(row["user_id"])})["Plaintext"]
    try:
        envelope = decrypt_payload(dek, bytes(row["encrypted_text"]))
    except Exception:  # noqa: BLE001 - unreadable is skipped, never guessed at
        return None
    if isinstance(envelope, dict):
        return envelope.get("text") or envelope.get("title")
    return envelope if isinstance(envelope, str) else None


def _wire_item(item: dict[str, Any]) -> dict[str, Any]:
    """One evidence row, as the request schema permits it to travel.

    The schema is an allowlist, so anything not named here cannot reach the
    model even by accident — and the two identifiers below travel to the *lane*,
    not to the gateway: they are how the invocation item is attributed, and the
    request document carries neither.
    """
    return {
        "item_index": item["item_index"],
        "fields": item["fields"],
        # Contract 8.1: the observed action IS request content — the gateway
        # copies it into the wire document, unlike the two identifiers below.
        "source_action": item.get("source_action"),
        "observation_id": str(item["observation_id"]),
        "source_text_evidence_id": str(item["source_text_evidence_id"]),
        "logical_extraction_key": item["logical_extraction_key"],
    }


def _write_model_mentions(connection, user_id: str, items: list[dict],
                          proposed: dict[str, Any]) -> int:
    """Write what the model proposed, each row naming the item that earned it.

    The mention is written by the deterministic worker — the identity that may
    write mentions and may not record invocations. That is the whole point of
    the handoff, and it is why the lineage arrives as a value rather than being
    looked up here.
    """
    by_index = {row["item_index"]: row for row in proposed["lineage"]}
    rows: list[dict] = []
    dictionary: list[tuple[dict, bool]] = []
    relations: list[tuple[dict, dict]] = []
    for answered in proposed["items"]:
        lineage = by_index.get(answered.get("item_index"))
        if lineage is None or lineage["outcome"] != "succeeded":
            # An item that did not succeed cannot carry mentions; the trigger
            # refuses it and the check constraint refused the count already.
            continue
        for mention in answered.get("mentions", []):
            inferred = mention.get("source_field") == "inferred"
            rows.append({
                "observation_id": lineage["observation_id"],
                "user_id": user_id,
                "mention_text": mention["surface"],
                "normalized_text": _normalize(mention["surface"]),
                "mention_role": mention.get("mention_role"),
                "type_hint": mention.get("family_hypothesis"),
                "source_field": mention.get("source_field"),
                "extraction_method": (
                    _INFERRED_METHOD if inferred else _MODEL_METHOD),
                "confidence": mention.get("confidence", 1.0),
                "evidence_weight": 1.0,
                "model_invocation_item_id": lineage["item_id"],
            })
            dictionary.append((mention, inferred))
            for relation in mention.get("relation_hypotheses") or []:
                relations.append((mention, relation))
    if not rows:
        return 0
    with connection.cursor() as cursor:
        cursor.executemany(_INSERT_MODEL_MENTION, rows)
    _write_dictionary(connection, dictionary, relations)
    return len(rows)


#: **Every term enters the dictionary, including the object of a relation.**
#: The owner's rule is unqualified, and the object is the whole reason a
#: franchise is known the first time any character of it is seen. `origin`
#: records how the term arrived; nothing here decides whether it is true.
_INSERT_PRESUMED_TERM = """
insert into semantic_private.presumed_terms
  (normalized_label, family, canonical_label, english_label, original_label,
   origin, source_lanes)
values (%(normalized_label)s, %(family)s, %(canonical_label)s,
        %(english_label)s, %(original_label)s, %(origin)s, %(source_lanes)s)
on conflict (normalized_label, family) do update
   set last_seen_at = now(),
       english_label = coalesce(semantic_private.presumed_terms.english_label,
                                excluded.english_label),
       original_label = coalesce(semantic_private.presumed_terms.original_label,
                                 excluded.original_label)
"""

#: A relation the model proposed, into the table `0203` built for exactly this
#: and nothing has ever written. `traversable` stays false by check constraint
#: until something verifies it, so a presumed relation can never be walked for
#: inference — which is what makes it safe to record one the model invented.
_INSERT_RELATION = """
insert into semantic_private.candidate_relation_proposals
  (user_id, subject_provisional_id, predicate, object_label_hypothesis,
   authority_state, traversable, provenance)
select null, p.id, %(predicate)s, %(object_label)s,
       'model_proposed', false,
       jsonb_build_object('source', 'model_lane', 'subject_surface', %(subject)s)
  from semantic_private.provisional_entities p
 where p.normalized_label = %(subject_normalized)s
 limit 1
on conflict do nothing
"""


def _write_dictionary(connection, dictionary: list[tuple[dict, bool]],
                      relations: list[tuple[dict, dict]]) -> None:
    """Put every proposed term in the dictionary, and record its relations.

    Failures here must never fail the extraction: the mentions are already
    written and are the evidence, while the dictionary is a global convenience
    rebuilt from them. A dictionary write that could roll back a person's
    distillation would be the tail wagging the dog.
    """
    entries = []
    for mention, inferred in dictionary:
        family = mention.get("family_hypothesis")
        if not family:
            continue
        entries.append({
            "normalized_label": _normalize(mention["surface"]),
            "family": family,
            "canonical_label": mention.get("canonical_label_hypothesis")
                               or mention["surface"],
            "english_label": mention.get("english_label"),
            "original_label": mention.get("original_label"),
            "origin": "inferred" if inferred else "extracted",
            "source_lanes": [],
        })

    try:
        with connection.cursor() as cursor:
            if entries:
                cursor.executemany(_INSERT_PRESUMED_TERM, entries)
            for mention, relation in relations:
                cursor.execute(_INSERT_RELATION, {
                    "predicate": relation["predicate"],
                    "object_label": relation["object_label_hypothesis"],
                    "subject": mention["surface"],
                    "subject_normalized": _normalize(mention["surface"]),
                })
    except Exception as error:  # noqa: BLE001 - reported, never fatal
        print(json.dumps({"dictionary_write_failed": type(error).__name__}))


def _normalize(surface: str) -> str:
    """The same normalisation the exact lane uses, asked for rather than copied.

    A second definition here would resolve differently from the one the exact
    resolver matches against, and the disagreement would look like the model
    proposing labels the ontology does not hold.
    """
    from written_ontology.normalize import normalize_text  # noqa: PLC0415

    return normalize_text(surface)


# ---------------------------------------------------------------------------
# 2. resolve_mention — the exact lane
# ---------------------------------------------------------------------------

#: **One statement, not a loop.** Resolving row by row would be 73,126 round
#: trips for one account, and the decision — how many distinct concepts carry
#: this normalized label at the published version — is a join the database is
#: better at than we are.
#:
#: The three outcomes are the contract's own: exactly one match is
#: `resolved_existing`, several is `ambiguous` (and asserts nothing, because a
#: name that means two things means neither), and none is `unresolved`, which is
#: the row `build_candidate_overlay` ignores and a later mint may rescue.
RESOLVE = """
with published as (
  select id from ontology.versions where status = 'published'
),
pending as (
  select m.id, m.user_id, m.normalized_text
    from semantic_private.observation_mentions m
    join semantic_private.observations o
      on o.id = m.observation_id and o.user_id = m.user_id
   where m.user_id = %(user_id)s
     and o.lifecycle_state = 'active'
     -- **Eligibility, before resolution rather than after.** An observation the
     -- scorer weighs at zero — an Apple `recommendation`, which is Apple's
     -- suggestion and not the person's act — is not a semantic opportunity, and
     -- counting it inflates every coverage number computed downstream. 1,080 of
     -- one account's 12,821 active mentions sat behind this line.
     and o.action_weight > 0
     and length(btrim(m.normalized_text)) > 0
     -- **Judged against the vocabulary now published, not merely judged.** The
     -- old condition skipped any mention that already had a row for this
     -- resolver and route, so a mention recorded `unresolved` could never be
     -- reconsidered — the record of the failure was what prevented the retry,
     -- and publishing new vocabulary rescued nothing. Keying on the evaluated
     -- version means a new ontology makes every negative verdict pending again,
     -- once, by itself.
     and not exists (
       select 1 from semantic_private.mention_resolutions r
        where r.mention_id = m.id
          and r.route_id = %(route)s
          and r.evaluated_ontology_version_id = (select id from published))
   order by m.id
   limit %(batch)s
),
matched as (
  select p.id, p.user_id, v.id as ontology_version_id,
         x.distinct_concepts, x.concept_id
    from pending p
   cross join published v
   left join lateral (
     select count(distinct l.concept_id) as distinct_concepts,
            -- **`min(uuid)` does not exist.** Postgres has no ordering aggregate
            -- for uuid, and the cast through text is what `0190` already does
            -- for the same reason. It is only ever read when the count is 1, so
            -- which uuid "min" picks is not a decision — there is one.
            min(l.concept_id::text)::uuid as concept_id
       from ontology.concept_labels l
       join ontology.concept_revisions cr
         on cr.ontology_version_id = l.ontology_version_id
        and cr.concept_id = l.concept_id
      where l.ontology_version_id = v.id
        and l.status = 'active'
        and cr.status = 'active'
        and l.normalized_label = p.normalized_text
   ) x on true
)
insert into semantic_private.mention_resolutions
  (user_id, mention_id, resolution, ontology_version_id, concept_id,
   route_id, resolver_version, confidence, abstention_reason,
   evaluated_ontology_version_id)
select m.user_id, m.id,
       case when m.distinct_concepts = 1 then 'resolved_existing'
            when m.distinct_concepts > 1 then 'ambiguous'
            else 'unresolved' end,
       case when m.distinct_concepts = 1 then m.ontology_version_id end,
       case when m.distinct_concepts = 1 then m.concept_id end,
       %(route)s, %(resolver_version)s,
       case when m.distinct_concepts = 1 then 1.0 else 0.0 end,
       case when m.distinct_concepts > 1 then 'ambiguous'
            when coalesce(m.distinct_concepts, 0) = 0 then 'no_durable_subject' end,
       -- Set on every row, including the negatives. `ontology_version_id` above
       -- is half a foreign key to `concept_revisions` and means where the
       -- concept lives; it is null exactly for the rows that need revisiting.
       m.ontology_version_id
  from matched m
on conflict do nothing
"""

#: **The current verdict per mention, never every historical one.** A mention
#: resolved under today's vocabulary still carries yesterday's `unresolved` row,
#: and a tally over the table would report it as both.
RESOLVE_TALLY = """
select resolution, count(*) as rows
  from semantic_private.current_mention_resolutions
 where user_id = %(user_id)s and route_id = %(route)s
 group by resolution
"""

REMAINING = """
select count(*) as remaining
  from semantic_private.observation_mentions m
  join semantic_private.observations o
    on o.id = m.observation_id and o.user_id = m.user_id
 where m.user_id = %(user_id)s
   and o.lifecycle_state = 'active'
   and o.action_weight > 0
   and length(btrim(m.normalized_text)) > 0
   and not exists (
     select 1 from semantic_private.mention_resolutions r
      where r.mention_id = m.id
        and r.route_id = %(route)s
        and r.evaluated_ontology_version_id
            = (select id from ontology.versions where status = 'published'))
"""


#: **The provisional lane lives in SQL, and this is the whole of the reason.**
#: Its proof has to seed rows and read them back, which a contract file can do
#: and a Python string constant cannot — `apply_feedback` is the standing example
#: of a statement no test can reach. `0234` owns the body; this calls it.
PROVISION = """
select minted, provisioned
  from semantic_private.provision_exact_misses(%(user_id)s::uuid, %(version)s::uuid)
"""


def resolve_mention(job) -> dict[str, Any]:
    """Resolve a bounded batch of one account's mentions against exact labels.

    No model, no network. A mention resolves when exactly one active concept at
    the published ontology version carries its normalized label — which is what
    *"resolve stable identifiers and exact aliases before any model call"* asks
    for, and is the whole of the exact lane.

    **`normalized_text` is compared, not `mention_text`.** The stored value was
    produced by `normalize_text`, and `concept_labels.normalized_label` by the
    same function; SQL cannot reproduce that fold, so comparing the raw surfaces
    would silently miss every accented, cased or width-variant name.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415 - Lambda flat layout

    payload = job.payload
    arguments = {
        "user_id": payload["user_id"],
        "resolver_version": payload["resolver_version"],
        "route": EXACT_ROUTE,
        "batch": RESOLVE_BATCH,
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            published = _published_version(cursor)
            if published is None:
                # Nothing to resolve against. A run that wrote `unresolved` for
                # every mention because the ontology was momentarily absent
                # would be indistinguishable from a library of unknown names.
                return {"status": "no_op", "abstained": True, "item_count": 0}

            cursor.execute(RESOLVE, arguments)
            written = cursor.rowcount

            # **The fallback runs inside this job, after the exact verdict for
            # the same bounded batch exists.** A separate stage would have to
            # decide for itself whether the exact lane had finished, and its
            # armer would need a route-aware work test to avoid a provisional
            # row satisfying the exact route's. One job, one transaction, and
            # the ordering is guaranteed rather than scheduled.
            cursor.execute(
                PROVISION, {"user_id": arguments["user_id"], "version": published}
            )
            fallback = cursor.fetchone()
            minted = fallback["minted"]
            provisioned = fallback["provisioned"]

            cursor.execute(RESOLVE_TALLY, arguments)
            tally = {row["resolution"]: row["rows"] for row in cursor.fetchall()}

            cursor.execute(REMAINING, arguments)
            remaining = cursor.fetchone()["remaining"]
        connection.commit()

    return {
        "status": "succeeded" if remaining == 0 else "partial",
        "item_count": written,
        "resolved_count": tally.get("resolved_existing", 0),
        "ambiguous_count": tally.get("ambiguous", 0),
        "unresolved_count": tally.get("unresolved", 0),
        "provisional_minted": minted,
        "provisional_count": provisioned,
        "remaining_count": remaining,
    }


# ---------------------------------------------------------------------------
# 3. build_candidate_overlay — resolutions become candidates
# ---------------------------------------------------------------------------

#: **`on conflict` names the partial index's predicate**, because that is how
#: Postgres infers which index to check. Omitting it raises rather than choosing
#: wrongly, which is the right failure but only if the statement is written to
#: expect it.
BUILD_CANDIDATES = """
insert into semantic_private.user_term_candidates
  (user_id, concept_id, user_facing_predicate, confidence_tier, primary_route_id)
select distinct r.user_id, r.concept_id, %(predicate)s, 'secondary', %(route)s
  from semantic_private.current_mention_resolutions r
 where r.user_id = %(user_id)s
   and r.resolution = 'resolved_existing'
   and r.concept_id is not null
on conflict (user_id, concept_id, user_facing_predicate)
  where lifecycle_state = 'active' and concept_id is not null
do nothing
"""

#: Evidence, one row per (candidate, observation, route). The unique key is what
#: makes a second pass free rather than doubling every contribution.
#:
#: **`contribution` is the mention's own evidence weight, bounded.** The column
#: is capped at 1.0 by check constraint, and a repeated fetch or a same-album
#: repost must not accumulate — a cap enforced only in the aggregator is a cap
#: one query can forget.
LINK_EVIDENCE = """
insert into semantic_private.candidate_support_links
  (user_id, candidate_id, observation_id, mention_resolution_id, route_id,
   evidence_family_key, contribution)
select c.user_id, c.id, m.observation_id, r.id, %(route)s,
       coalesce(m.type_hint, 'unspecified'),
       least(greatest(m.evidence_weight * m.recency_weight, 0.0), 1.0)
  from semantic_private.current_mention_resolutions r
  join semantic_private.observation_mentions m
    on m.id = r.mention_id and m.user_id = r.user_id
  join semantic_private.user_term_candidates c
    on c.user_id = r.user_id
   and c.concept_id = r.concept_id
   and c.user_facing_predicate = %(predicate)s
   and c.lifecycle_state = 'active'
 where r.user_id = %(user_id)s
   and r.resolution = 'resolved_existing'
   and r.concept_id is not null
   -- **The anti-join is what makes the limit a page rather than a wall.**
   -- Without it every pass selects the same arbitrary 5,000 rows, conflicts
   -- them all away, and evidence beyond the first page is unreachable — the
   -- limit stops being a batch size and becomes a ceiling on how much of
   -- somebody's library can ever support a term.
   and not exists (
     select 1 from semantic_private.candidate_support_links l
      where l.candidate_id = c.id
        and l.observation_id = m.observation_id
        and l.route_id = %(route)s)
 -- And stable ordering, so successive pages are successive rather than a
 -- reshuffle of whatever the planner returned.
 order by r.id
 limit %(batch)s
on conflict (candidate_id, observation_id, route_id) do nothing
"""


#: The candidate and evidence half of the same lane, for the same reason.
BUILD_PROVISIONAL = """
select candidates, links
  from semantic_private.build_provisional_candidates(
         %(user_id)s::uuid, %(predicate)s, %(batch)s::integer)
"""


def build_candidate_overlay(job) -> dict[str, Any]:
    """Turn resolved mentions into candidate terms and the evidence under them.

    A candidate is one concept a person might be said to have an affinity for,
    and it is *not* an assertion: nothing here writes `user_assertions`, nothing
    reaches a surface, and `api.list_assertions` cannot see any of it. That
    separation is the point of an overlay — a claim has to survive scoring and
    a review before it becomes something said about somebody.

    Candidates arrive `secondary`; `aggregate_term_candidates` decides tier from
    the evidence rather than this job asserting one on the way in.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    arguments = {
        "user_id": job.payload["user_id"],
        "route": EXACT_ROUTE,
        "predicate": EXACT_PREDICATE,
        "batch": CANDIDATE_BATCH,
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(BUILD_CANDIDATES, arguments)
            candidates = cursor.rowcount
            cursor.execute(LINK_EVIDENCE, arguments)
            links = cursor.rowcount

            cursor.execute(BUILD_PROVISIONAL, arguments)
            provisional = cursor.fetchone()
            candidates += provisional["candidates"]
            links += provisional["links"]
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": candidates,
        # **`changed` is a boolean here, not a count.**
        # `worker_job_result_is_safe_v03` types it, and a receipt that
        # failed that check would fail the *job*, after the work had
        # already committed.
        "changed": bool(candidates or links),
    }


# ---------------------------------------------------------------------------
# 4. aggregate_term_candidates — scoring
# ---------------------------------------------------------------------------

#: **The same saturation the scorer uses**, so a candidate's number and the
#: assertion it may become are on one scale and a reviewer comparing them is
#: comparing like with like.
#:
#: Tier is read off the bar rather than invented: at or above `0.35` the
#: evidence would clear what an assertion needs, which is `inferred`; below it
#: the evidence is real and has not earned a claim, which is `secondary`.
#: `direct` is reserved for something the person said, and nothing in the exact
#: lane can produce that.
AGGREGATE = """
with clustered as (
  -- **One opinion per correlated cluster (three-lane contract §5.2).** Forty
  -- videos from one channel are one channel's enthusiasm, not forty
  -- independent witnesses — the same damping the genre rollup applies with
  -- "one mapping per (genre, artist)". The cluster is the channel where the
  -- observation names one, and the observation itself everywhere else, so
  -- reposts and same-channel floods collapse to their strongest single row
  -- while genuinely distinct provider items still add.
  select l.candidate_id,
         coalesce(o.normalized_payload ->> 'channel_id',
                  l.observation_id::text) as cluster_key,
         max(l.contribution) as cluster_contribution,
         count(*) as rows_in_cluster
    from semantic_private.candidate_support_links l
    join semantic_private.observations o
      on o.id = l.observation_id
   where l.user_id = %(user_id)s
   group by l.candidate_id, 2
),
weighed as (
  select candidate_id,
         sum(cluster_contribution) as total,
         sum(rows_in_cluster) as evidence_rows
    from clustered
   group by candidate_id
)
update semantic_private.user_term_candidates c
   set aggregate_score = w.total / (w.total + %(saturation)s),
       confidence_tier = case
         when w.total / (w.total + %(saturation)s) >= %(bar)s then 'inferred'
         else 'secondary' end,
       updated_at = now()
  from weighed w
 where c.id = w.candidate_id
   and c.user_id = %(user_id)s
   and c.lifecycle_state = 'active'
   and (c.aggregate_score is distinct from w.total / (w.total + %(saturation)s)
        or c.confidence_tier is distinct from case
             when w.total / (w.total + %(saturation)s) >= %(bar)s then 'inferred'
             else 'secondary' end)
"""

TIER_TALLY = """
select confidence_tier, count(*) as rows
  from semantic_private.user_term_candidates
 where user_id = %(user_id)s and lifecycle_state = 'active'
 group by confidence_tier
"""


def aggregate_term_candidates(job) -> dict[str, Any]:
    """Score every active candidate from the evidence beneath it.

    **Only rows whose score or tier actually moves are written.** An update that
    touched every candidate each pass would churn `updated_at` on thousands of
    rows for no change, and make "when did this term last move" unanswerable —
    which is the question a reviewer asks first.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    arguments = {
        "user_id": job.payload["user_id"],
        "saturation": SATURATION,
        "bar": ELIGIBILITY,
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(AGGREGATE, arguments)
            moved = cursor.rowcount
            cursor.execute(TIER_TALLY, {"user_id": arguments["user_id"]})
            tiers = {row["confidence_tier"]: row["rows"] for row in cursor.fetchall()}
        connection.commit()

    return {
        "status": "succeeded",
        "changed": bool(moved),
        "item_count": sum(tiers.values()),
        "inferred_count": tiers.get("inferred", 0),
        "secondary_count": tiers.get("secondary", 0),
    }


# ---------------------------------------------------------------------------
# 5. build_review_items — what a person is shown
# ---------------------------------------------------------------------------

#: **Suppressed terms are excluded here and not at draw time.** A strike is a
#: person saying "not this", and the honest place to honour it is before the
#: card is built — a review item that exists and is filtered later still appears
#: in the exposure history as something they were shown.
BUILD_REVIEW = """
with ranked as (
  select c.id, c.user_id, c.confidence_tier, c.aggregate_score, c.primary_route_id,
         -- **Ranks continue the epoch, and discovery goes first.** The old
         -- row_number() numbered within each builder pass, and passes run
         -- every few minutes adding one or two candidates — so an 847-item
         -- epoch collapsed to rank 0 and the review surface handed out an
         -- arbitrary, permanently identical eight. The offset makes rank an
         -- epoch-wide position; the discovery-first key puts model-proposed
         -- provisionals — the reason this lane exists — above known-concept
         -- candidates whatever their aggregate score.
         row_number() over (order by (c.provisional_entity_id is not null) desc,
                            c.aggregate_score desc, c.id) - 1
           + coalesce((select max(i0.rank) + 1
                         from semantic_private.review_items i0
                        where i0.user_id = %(user_id)s
                          and i0.review_epoch = %(epoch)s), 0) as rank
    from semantic_private.user_term_candidates c
   where c.user_id = %(user_id)s
     and c.lifecycle_state = 'active'
     -- **Already on this epoch's page, so not a candidate for it again.**
     -- Without this the builder re-selects the same highest-ranked 24 every
     -- pass, conflicts them away, and candidate 25 is unreachable for the life
     -- of the epoch.
     and not exists (
       select 1 from semantic_private.review_items i
        where i.candidate_id = c.id and i.review_epoch = %(epoch)s)
     and not exists (
       select 1 from semantic_private.user_term_suppressions s
        where s.user_id = c.user_id
          and s.active
          and s.user_facing_predicate = c.user_facing_predicate
          and (s.concept_id = c.concept_id
               or s.provisional_entity_id = c.provisional_entity_id))
   order by (c.provisional_entity_id is not null) desc,
            c.aggregate_score desc, c.id
   limit %(page)s
)
insert into semantic_private.review_items
  (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
   aggregate_score, rank, presentation_version)
select r.user_id, r.id, %(epoch)s, r.primary_route_id, r.confidence_tier,
       r.aggregate_score, r.rank, %(presentation)s
  from ranked r
on conflict (user_id, candidate_id, review_epoch) do nothing
"""

LINK_REVIEW_EVIDENCE = """
insert into semantic_private.review_item_evidence
  (review_item_id, user_id, support_link_id)
select i.id, i.user_id, l.id
  from semantic_private.review_items i
  join semantic_private.candidate_support_links l
    on l.candidate_id = i.candidate_id and l.user_id = i.user_id
 where i.user_id = %(user_id)s and i.review_epoch = %(epoch)s
on conflict do nothing
"""

LINK_REVIEW_ROUTES = """
insert into semantic_private.review_item_routes
  (review_item_id, user_id, route_id, is_primary)
select i.id, i.user_id, i.primary_route_id, true
  from semantic_private.review_items i
 where i.user_id = %(user_id)s and i.review_epoch = %(epoch)s
on conflict do nothing
"""


def build_review_items(job) -> dict[str, Any]:
    """Build one epoch's review page for a person.

    `review_items` is append-only by trigger, so this can be run twice and the
    second run writes nothing — `review_items_one_card_per_epoch` refuses the
    duplicate rather than the trigger having to.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    contract = load_contract()
    arguments = {
        "user_id": job.payload["user_id"],
        "epoch": job.payload["review_epoch"],
        "page": REVIEW_PAGE,
        # The presentation is versioned so a feedback label stays interpretable:
        # "they struck this" means nothing except against the arrangement it was
        # struck in.
        "presentation": contract.versions["grammar"],
    }

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(BUILD_REVIEW, arguments)
            items = cursor.rowcount
            cursor.execute(LINK_REVIEW_ROUTES, arguments)
            cursor.execute(LINK_REVIEW_EVIDENCE, arguments)
            evidence = cursor.rowcount
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": items,
        "changed": bool(items or evidence),
    }


# ---------------------------------------------------------------------------
# 6. apply_feedback — a person's answers take effect
# ---------------------------------------------------------------------------

#: A strike suppresses the term for that predicate. **`on conflict do nothing`
#: against the partial unique index**, so striking the same term twice is one
#: suppression rather than an error — a person tapping twice is not a conflict.
#:
#: **It selected both target columns and then threw the provisional half away.**
#: `and c.concept_id is not null` is exactly `and not provisional-backed`, the
#: schema's own single-term check making it so, and the conflict target named
#: only the concept index. A strike on a provisional-backed candidate produced no
#: suppression at all — silently, since the receipt counts rows.
#:
#: Two statements rather than one predicate, because the two partial indexes are
#: two arbiters and `on conflict` infers one at a time. Deleting the filter
#: without splitting the statement would turn a silent drop into a `23505` on the
#: second strike of the same provisional, which is worse only in that it is
#: louder.
SUPPRESS_CONCEPT = """
insert into semantic_private.user_term_suppressions
  (user_id, concept_id, provisional_entity_id, user_facing_predicate,
   source_review_item_id, source_review_epoch)
select e.user_id, c.concept_id, c.provisional_entity_id,
       c.user_facing_predicate, i.id, i.review_epoch
  from semantic_private.review_events e
  join semantic_private.review_items i on i.id = e.review_item_id
  join semantic_private.user_term_candidates c on c.id = i.candidate_id
 where e.user_id = %(user_id)s
   and e.action = 'strike_off'
   and c.concept_id is not null
on conflict (user_id, concept_id, user_facing_predicate)
  where active and concept_id is not null
do nothing
"""

SUPPRESS_PROVISIONAL = """
insert into semantic_private.user_term_suppressions
  (user_id, concept_id, provisional_entity_id, user_facing_predicate,
   source_review_item_id, source_review_epoch)
select e.user_id, c.concept_id, c.provisional_entity_id,
       c.user_facing_predicate, i.id, i.review_epoch
  from semantic_private.review_events e
  join semantic_private.review_items i on i.id = e.review_item_id
  join semantic_private.user_term_candidates c on c.id = i.candidate_id
 where e.user_id = %(user_id)s
   and e.action = 'strike_off'
   and c.provisional_entity_id is not null
on conflict (user_id, provisional_entity_id, user_facing_predicate)
  where active and provisional_entity_id is not null
do nothing
"""

#: A struck candidate is withdrawn, not deleted. The evidence under it stays —
#: what somebody declined to be described by is not evidence that the underlying
#: observation never happened.
#:
#: **Both identity columns, and the second one is not symmetry for its own sake.**
#: The schema forces exactly one of them non-null on each side, so for a
#: provisional-backed suppression meeting a provisional-backed candidate
#: `s.concept_id is not distinct from c.concept_id` reads `null is not distinct
#: from null`, which is true. With the lane holding one predicate that left
#: `user_id`, `active` and `lifecycle_state` as the only discriminators: **one
#: strike would have withdrawn every active provisional candidate that person
#: had.** `BUILD_REVIEW` a hundred lines above already gets this right with `=`,
#: which yields unknown on two nulls; the two statements disagreed.
#:
#: It is latent only because `SUPPRESS` never wrote a provisional row. Repairing
#: that alone would have armed this from the other side, which is why they are
#: one change.
WITHDRAW = """
update semantic_private.user_term_candidates c
   set lifecycle_state = 'withdrawn', updated_at = now()
  from semantic_private.user_term_suppressions s
 where c.user_id = %(user_id)s
   and s.user_id = c.user_id
   and s.active
   and s.user_facing_predicate = c.user_facing_predicate
   and s.concept_id is not distinct from c.concept_id
   and s.provisional_entity_id is not distinct from c.provisional_entity_id
   and c.lifecycle_state = 'active'
"""


def apply_feedback(job) -> dict[str, Any]:
    """Turn one person's review answers into suppressions.

    **Only `strike_off` acts.** `keep` and `confirm` are signal for ranking and
    change nothing about what is stored, and `edit` needs a corrected term that
    the exact lane has no way to mint yet — recorded, not acted on, which is
    better than acting on it wrongly.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    arguments = {"user_id": job.payload["user_id"]}

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(SUPPRESS_CONCEPT, arguments)
            suppressed = cursor.rowcount
            cursor.execute(SUPPRESS_PROVISIONAL, arguments)
            suppressed += cursor.rowcount
            cursor.execute(WITHDRAW, arguments)
            withdrawn = cursor.rowcount
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": suppressed,
        "changed": bool(suppressed or withdrawn),
    }


# ---------------------------------------------------------------------------
# 7. aggregate_feedback — how each route is doing
# ---------------------------------------------------------------------------

#: Keep and strike counts per route, across everybody. **A route rather than a
#: term**: the question this answers is which way of reaching a term produces
#: ones people accept, which is what decides whether a route is worth running.
ROUTE_STATS = """
select i.primary_route_id as route,
       count(*) filter (where e.action in ('keep', 'confirm')) as kept,
       count(*) filter (where e.action = 'strike_off') as struck,
       count(*) as answered
  from semantic_private.review_events e
  join semantic_private.review_items i on i.id = e.review_item_id
 group by i.primary_route_id
 order by answered desc
 limit 8
"""


def aggregate_feedback(job) -> dict[str, Any]:
    """Fleet-wide keep/strike rates per route.

    A system job: it names no user, and `worker_job_payload_is_valid_v03` allows
    that only where the queue row's `user_id` is null too.

    **It writes nothing.** Precision per route is a number to read before
    changing a route, and storing it would mean a table whose schema encodes
    which statistics matter — a decision worth making when there is enough
    feedback to make it. Today there is none, and the receipt says so.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(ROUTE_STATS)
            rows = cursor.fetchall()

    answered = sum(row["answered"] for row in rows)
    struck = sum(row["struck"] for row in rows)
    return {
        "status": "succeeded" if answered else "no_op",
        "item_count": answered,
        "changed": bool(rows),
        "struck_count": struck,
    }


# ---------------------------------------------------------------------------
# 8. evaluate_release — the gate report
# ---------------------------------------------------------------------------

#: Which evaluator reached a verdict. Bumped when what the job checks changes,
#: so two reports on one manifest are comparable rather than merely consecutive.
EVALUATION_REVISION = "release-eval-0.2.0"

#: **A verdict is appended, never overwritten.** This was a blind
#: `update ... set gate_report`, so every re-run destroyed the previous verdict
#: and the question *"did this release ever pass, and when did it stop"* had no
#: answer. `0235` makes the table append-only by trigger and revokes the column
#: privilege that allowed the overwrite.
RECORD_GATE = """
insert into ontology.release_gate_reports
  (release_manifest_id, evaluation_revision, environment, report)
values (%(release_manifest_id)s, %(evaluation_revision)s, %(environment)s,
        %(report)s::jsonb)
"""

#: **Every field the runtime attestation declares, and the query is built from
#: those keys.** It selected three columns and compared one, while reading a
#: fourth — `model_lane_mode` — that the select did not carry and the table did
#: not have, so that test was `failed` for every row that could ever exist. A
#: query written by hand beside a comparison written by hand is two lists, and
#: this is what happens to two lists.
#:
#: `0235` gives each of these a column. A key added to `attestation()` with no
#: column here raises at the start of the job rather than going uncompared.
ATTESTED_COLUMNS = (
    "compiled_contract_sha256",
    "workbook_sha256",
    "schema_sha256",
    "request_schema_sha256",
    "grammar_version",
    "prompt_version",
    "model_id",
    "model_revision",
    "gateway_revision",
    # **`0235` named the manifest column `tokenizer_runtime_manifest_sha256`**,
    # and the contract's expectation is `tokenizer_manifest_sha256`. The two
    # are the same fact under two names, which is why the crosswalk is written
    # down here rather than performed by whoever reads it next.
    "tokenizer_runtime_manifest_sha256",
    "serving_image_digest",
    "model_lane_mode",
)

#: Contract expectation -> manifest column, where the two are not spelled alike.
#: Without this the completeness check below sees two names it does not
#: recognise and raises on every release, which is how adding an expectation
#: quietly broke the evaluator.
MANIFEST_COLUMN_FOR = {
    "tokenizer_manifest_sha256": "tokenizer_runtime_manifest_sha256",
}

MANIFEST = f"""
select {', '.join(ATTESTED_COLUMNS)}, environment, promotion_decision
  from ontology.release_manifests
 where id = %(release_manifest_id)s
"""


def process_mint_requests(job) -> dict[str, Any]:
    """Run the catalogue processor over pending kept requests.

    The worker never writes vocabulary: `semantic_worker` holds no insert on
    any `ontology` table, and the whole transaction — disposition, collision
    checks, version publish, provisional linking, request completion,
    per-user recompute bump — lives in
    `semantic_private.mint_from_kept_requests`, which is `security definer`
    for exactly the reason `mint_vocabulary_from_catalogue` is: the thing
    reachable from a queue must not be able to rewrite shared vocabulary at
    will. The job payload names one request for provenance, but the function
    drains every pending request it can lock — a second job for a request the
    first pass already completed conflicts on the idempotency key or finds
    nothing pending, which is the exactly-once the memo demands.
    """
    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    with psycopg.connect(database_url(), row_factory=dict_row,
                         prepare_threshold=None) as connection:
        parents = _kept_parents(connection)
        with connection.cursor() as cursor:
            cursor.execute(
                "select semantic_private.mint_from_kept_requests(%(parents)s) as receipt",
                {"parents": json.dumps(parents)})
            receipt = cursor.fetchone()["receipt"]
        # **The ontology version leaves the receipt.** `mint_requests.outcome`
        # already records which version each decision landed in, and the job
        # result's closed vocabulary has no place for a free string — `0262`
        # admitted `version` among the *uuid* keys, which no version string can
        # ever satisfy, so every mint committed its work and then died writing
        # its own bookkeeping. A receipt duplicating a fact the ledger holds is
        # a second copy that can disagree with the first.
        receipt = {k: v for k, v in (receipt or {}).items() if k != "version"}

        # **The ones minted before the parent was derived.** Same resolution,
        # same writer, run after the mint so a concept created moments ago is
        # included if its own parent could not be resolved then. A no-op once
        # nothing floats, which is the steady state.
        orphans = _orphan_kept_parents(connection)
        if orphans:
            with connection.cursor() as cursor:
                cursor.execute(
                    "select semantic_private.attach_kept_concept_parents(%(parents)s) as receipt",
                    {"parents": json.dumps(orphans)})
                cursor.fetchone()
        connection.commit()
    return {"processed": True, **receipt}


#: Kept concepts that reach no block, with the genre strings stated on the
#: evidence behind the request that minted them. Keyed by concept because the
#: request itself is finished and immutable — its record is history, and this
#: repairs the vocabulary rather than rewriting the decision.
SELECT_ORPHAN_KEPT_CONCEPTS = """
select (mr.outcome ->> 'concept_id')::uuid as concept_id,
       coalesce(
         jsonb_agg(distinct g) filter (where g is not null), '[]'::jsonb
       ) as stated_genres,
       -- **YouTube states topics where music states genres**, and reading one
       -- is the same act as reading the other: `topicDetails.topicCategories`
       -- is the source's own label, which III.E.4 permits reading and forbids
       -- only inferring. Without this a YouTube keep has nothing to be placed
       -- by, and the lane the discovery rule exists for is the one that floats.
       coalesce(
         jsonb_agg(distinct t) filter (where t is not null), '[]'::jsonb
       ) as stated_topics,
       min(o.source_code) as source_code
  from semantic_private.mint_requests mr
  left join semantic_private.candidate_support_links l
    on l.candidate_id = mr.candidate_id and l.user_id = mr.user_id
  left join semantic_private.observations o
    on o.id = l.observation_id
  left join lateral jsonb_array_elements_text(
         case when jsonb_typeof(o.normalized_payload -> 'genres') = 'array'
              then o.normalized_payload -> 'genres' else '[]'::jsonb end) g on true
  left join lateral jsonb_array_elements_text(
         case when jsonb_typeof(o.normalized_payload -> 'topics') = 'array'
              then o.normalized_payload -> 'topics' else '[]'::jsonb end) t on true
 where mr.status = 'completed'
   and mr.outcome ->> 'concept_id' is not null
   and semantic_private.concept_block(
         (mr.outcome ->> 'concept_id')::uuid,
         (select id from ontology.versions where status = 'published')) is null
 group by 1
"""


def _orphan_kept_parents(connection) -> dict[str, str]:
    """`{concept_id: parent_concept_id}` for kept concepts that reach no block."""
    with connection.cursor() as cursor:
        cursor.execute(SELECT_ORPHAN_KEPT_CONCEPTS)
        rows = [dict(row) for row in cursor.fetchall()]
    if not rows:
        return {}
    return _resolve_parents(connection, rows, key="concept_id")


#: The genre strings the source states about a pending request's own evidence.
#:
#: **Read, never inferred.** Apple states `genres` on the observation itself,
#: which is the same fact the genre rollup already treats as `provider_metadata`
#: — so a kept term's parent is something the source said, not something this
#: code decided. The alternative was `0258`'s: no parent at all, on the reasoning
#: that "one parented to a guess is a false claim". True, and the premise was
#: wrong — there is no guess to make when the row carries the answer.
SELECT_KEPT_EVIDENCE_GENRES = """
select mr.id as mint_request_id,
       coalesce(
         jsonb_agg(distinct g) filter (where g is not null), '[]'::jsonb
       ) as stated_genres,
       -- **YouTube states topics where music states genres**, and reading one
       -- is the same act as reading the other: `topicDetails.topicCategories`
       -- is the source's own label, which III.E.4 permits reading and forbids
       -- only inferring. Without this a YouTube keep has nothing to be placed
       -- by, and the lane the discovery rule exists for is the one that floats.
       coalesce(
         jsonb_agg(distinct t) filter (where t is not null), '[]'::jsonb
       ) as stated_topics,
       min(o.source_code) as source_code
  from semantic_private.mint_requests mr
  left join semantic_private.candidate_support_links l
    on l.candidate_id = mr.candidate_id and l.user_id = mr.user_id
  left join semantic_private.observations o
    on o.id = l.observation_id
  left join lateral jsonb_array_elements_text(
         case when jsonb_typeof(o.normalized_payload -> 'genres') = 'array'
              then o.normalized_payload -> 'genres' else '[]'::jsonb end) g on true
  left join lateral jsonb_array_elements_text(
         case when jsonb_typeof(o.normalized_payload -> 'topics') = 'array'
              then o.normalized_payload -> 'topics' else '[]'::jsonb end) t on true
 where mr.status = 'pending'
 group by mr.id
"""

#: How deep a genre sits under its own root, so the most specific of several
#: stated genres can be chosen **from the graph** rather than from a list of
#: names somebody ranked. `K-Pop` is deeper than `Pop`, and nothing here had to
#: know that.
SELECT_GENRE_DEPTHS = """
with recursive climb(concept_id, depth) as (
  select cr.concept_id, 0
    from ontology.concept_revisions cr
    join ontology.versions v on v.id = cr.ontology_version_id
   where v.status = 'published' and cr.status = 'active'
     and cr.concept_kind = 'genre'
  union all
  select climb.concept_id, climb.depth + 1
    from climb
    join ontology.concept_edges e
      on e.subject_concept_id = climb.concept_id
     and e.predicate_key = 'broader'
     and e.status = 'active'
     and e.ontology_version_id = (select id from ontology.versions where status = 'published')
   where climb.depth < 8
)
select concept_id, max(depth) as depth from climb group by concept_id
"""

#: Anything a term may be filed under: the genres above plus hubs and topics,
#: which is what a YouTube topic slug resolves to. Same rule as the genre join
#: — a label naming more than one concept resolves to nothing rather than to a
#: guess.
SELECT_PLACEABLE_CONCEPTS = """
select l.normalized_label, min(l.concept_id::text)::uuid as concept_id
  from ontology.concept_labels l
  join ontology.concept_revisions cr
    on cr.concept_id = l.concept_id and cr.ontology_version_id = l.ontology_version_id
  join ontology.versions v on v.id = l.ontology_version_id
 where v.status = 'published' and l.status = 'active' and cr.status = 'active'
   and cr.concept_kind in ('hub', 'topic', 'genre')
 group by l.normalized_label
having count(distinct l.concept_id) = 1
"""

#: The hub a source's own material belongs to. Reading it is not a claim about
#: the term — it is a claim about where the material came from, which the source
#: code already states.
SELECT_SOURCE_HUB = """
select c.id as concept_id
  from ontology.concepts c
 where c.concept_key = %(hub_key)s
"""

#: Music sources land under the music hub. Not a genre and not a guess: the
#: floor beneath a term whose stated genre this vocabulary cannot yet name.
#: The five `refusedTopics` families, dropped wherever a topic is read. Named
#: here because this is a second place topics are read and the rule is the
#: app's, not this file's invention.
_REFUSED_TOPIC_WORDS = ("Religion", "Politic", "Health", "Military", "Society")

_SOURCE_HUBS = {
    "apple_music": "hub:music",
    "music_library": "hub:music",
    "spotify": "hub:music",
}


def _kept_parents(connection) -> dict[str, str]:
    """Resolve each pending mint request to the concept its evidence names.

    Returns `{mint_request_id: concept_id}` for the trusted catalogue layer to
    write; nothing here inserts anything. The fold happens in Python because
    `normalize_text` is a Unicode-category operation Postgres cannot reproduce
    — the same reason `catalogue.py` normalises there and joins on the stored
    value.
    """
    from written_ontology.normalize import normalize_text  # noqa: PLC0415

    try:
        from music_works import english_genre  # noqa: PLC0415
    except ImportError:  # pragma: no cover - the bundle always carries it
        def english_genre(text: str) -> str:
            return text

    with connection.cursor() as cursor:
        cursor.execute(SELECT_KEPT_EVIDENCE_GENRES)
        pending = [dict(row) for row in cursor.fetchall()]
        if not pending:
            return {}

        # **Mint what the vocabulary cannot yet name, before resolving.** `0191`'s
        # suffix rule is the one that decides — it mints `Vocal Jazz` under
        # `Jazz` and declines to guess synonymy for a string with no held
        # suffix. Called first so the resolution below sees anything it added.
        cursor.execute("select semantic_private.mint_genres_from_stated_strings()")

        cursor.execute(SELECT_GENRE_CONCEPTS)
        by_label = {row["normalized_label"]: str(row["concept_id"])
                    for row in cursor.fetchall()}
        cursor.execute(SELECT_PLACEABLE_CONCEPTS)
        for row in cursor.fetchall():
            by_label.setdefault(row["normalized_label"], str(row["concept_id"]))
        cursor.execute(SELECT_GENRE_DEPTHS)
        depth = {str(row["concept_id"]): row["depth"] for row in cursor.fetchall()}

    return _resolve_parents(connection, pending, key="mint_request_id",
                            by_label=by_label, depth=depth)


def _resolve_parents(connection, rows: list[dict], *, key: str,
                     by_label: dict | None = None,
                     depth: dict | None = None) -> dict[str, str]:
    """The ladder, in one place because two copies would drift apart.

    Stated genre -> the resolver's own label join -> the deepest of several,
    read off the graph -> the source's own hub. Nothing here maps a name to a
    genre; the join is what the resolver already uses.
    """
    from written_ontology.normalize import normalize_text  # noqa: PLC0415

    try:
        from music_works import english_genre  # noqa: PLC0415
    except ImportError:  # pragma: no cover - the bundle always carries it
        def english_genre(text: str) -> str:
            return text

    if by_label is None or depth is None:
        with connection.cursor() as cursor:
            cursor.execute(SELECT_GENRE_CONCEPTS)
            by_label = {row["normalized_label"]: str(row["concept_id"])
                        for row in cursor.fetchall()}
            cursor.execute(SELECT_PLACEABLE_CONCEPTS)
            for row in cursor.fetchall():
                by_label.setdefault(row["normalized_label"], str(row["concept_id"]))
            cursor.execute(SELECT_GENRE_DEPTHS)
            depth = {str(row["concept_id"]): row["depth"]
                     for row in cursor.fetchall()}

    parents: dict[str, str] = {}
    for row in rows:
        stated = row["stated_genres"] or []
        candidates = []
        for name in stated:
            concept = by_label.get(normalize_text(english_genre(name) or ""))
            if concept is not None:
                candidates.append(concept)
        # **Then what YouTube states**, folded from its slug — `Pop_music`
        # is written the way Wikipedia writes it, not the way a label is.
        # Refused topics are dropped here as everywhere else: a content tag is
        # how a protected characteristic arrives without anyone deciding to
        # collect it.
        for name in (row.get("stated_topics") or []):
            if any(word in name for word in _REFUSED_TOPIC_WORDS):
                continue
            concept = by_label.get(normalize_text(name.replace("_", " ")))
            if concept is not None:
                candidates.append(concept)
        if candidates:
            # The deepest stated genre — most specific wins, read off the graph.
            parents[str(row[key])] = max(
                candidates, key=lambda c: (depth.get(c, 0), c))
            continue

        hub_key = _SOURCE_HUBS.get(row.get("source_code") or "")
        if hub_key is None:
            continue
        with connection.cursor() as cursor:
            cursor.execute(SELECT_SOURCE_HUB, {"hub_key": hub_key})
            hub = cursor.fetchone()
        if hub is not None:
            parents[str(row[key])] = str(hub["concept_id"])

    return parents


def evaluate_release(job) -> dict[str, Any]:
    """Check a release manifest against the contract the worker is running.

    The one gate a *running* Lambda can answer that CI cannot: whether the
    contract this deployed bundle actually loaded is the one the manifest was
    recorded against. CI compares artifacts to each other; only this compares an
    artifact to what is in production.

    A mismatch is written into the report rather than raised. The job's purpose
    is to produce the report, and a job that dies instead of recording the
    failure it found leaves the manifest looking unevaluated.
    """
    import json

    import psycopg
    from psycopg.rows import dict_row

    from handler import database_url  # noqa: PLC0415

    contract = load_contract()
    manifest_id = job.payload["release_manifest_id"]

    # **A field the attestation declares and the manifest has no column for is a
    # field nothing compares.** Raised here rather than skipped, because the
    # failure this job exists to prevent is exactly a test that looks present and
    # cannot run.
    uncompared = sorted(
        {MANIFEST_COLUMN_FOR.get(name, name) for name in contract.attestation()}
        - set(ATTESTED_COLUMNS))
    if uncompared:
        raise RuntimeError(
            f"the runtime attestation declares {uncompared} and the release "
            "manifest has no column for them; add the column before attesting"
        )

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(MANIFEST, {"release_manifest_id": manifest_id})
            manifest = cursor.fetchone()
            if manifest is None:
                return {"status": "no_op", "abstained": True, "item_count": 0}

            attested = contract.attestation()
            # One test per attested field, in the attestation's own order. The
            # **deployed mode must match what the manifest attested**, rather
            # than being required to be off unconditionally — the pre-`0230`
            # test could never pass once the lane ran at all, which made
            # `candidate_attestation` and `staging_e2e` unreachable: both
            # require the lane to have run, and the gate demanded it had not.
            # **The mapped column, for every comparison.** The completeness
            # check learned the crosswalk and this did not, so
            # `manifest["tokenizer_manifest_sha256"]` raised `KeyError` on every
            # release — the row calls it `tokenizer_runtime_manifest_sha256`.
            # A raised evaluator is worse than a failing one: a failed report is
            # recorded and readable, an exception is a job that died.
            #
            # The test id keeps the **contract** field name, because that is what
            # a reader is checking against; the column is an implementation
            # detail of where the manifest keeps it.
            tests = [
                {
                    "id": f"{field}_matches_manifest",
                    "status": (
                        "passed"
                        if manifest.get(MANIFEST_COLUMN_FOR.get(field, field)) == value
                        else "failed"
                    ),
                }
                for field, value in attested.items()
            ]
            passed = all(test["status"] == "passed" for test in tests)
            report = {
                "schema_version": "semantic_gate_report_v1",
                "test_results": tests,
                # The verdict, stated once. It was derivable from the list and
                # the receipt derived something else.
                "all_required_tests_passed": passed,
                **attested,
            }
            cursor.execute(
                RECORD_GATE,
                {
                    "release_manifest_id": manifest_id,
                    "evaluation_revision": EVALUATION_REVISION,
                    "environment": manifest["environment"],
                    "report": json.dumps(report),
                },
            )
        connection.commit()

    return {
        "status": "succeeded",
        "item_count": len(report["test_results"]),
        # **`changed` means the release is attested**, which is what a caller
        # reading a receipt wants to know. It was the contract-hash comparison
        # alone, so this said `true` over a report whose second test read
        # `failed` — a green receipt covering a red gate, which is worse than a
        # red one.
        "changed": passed,
    }
