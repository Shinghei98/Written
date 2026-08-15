"""The semantic worker, as a Lambda.

**It is the vendored package, not a reimplementation.** `SemanticWorker` and
`PostgresJobQueue` come from `written_ontology`, which is the contract's own
implementation and has its own tests — claim with `FOR UPDATE SKIP LOCKED`,
lease tokens, attempt limits, payload validation against the job contracts, and
a fail-closed default where an unhandled job type is marked dead rather than
succeeded. Writing a second queue in another language would have meant the
thing running in production was not the thing the tests cover.

What this file adds is the two things a Lambda needs and the package
deliberately does not have: where the database lives, and a handler.

Runs on an EventBridge schedule. `run_once` claims at most one job per
invocation, which is the package's own shape — the CLI *requires* `--once` —
so the schedule is the loop.
"""

from __future__ import annotations

import json
import os
import uuid
from typing import Any

import boto3

from written_ontology.repository import PostgresJobQueue, WorkerJob
from written_ontology.worker import SemanticWorker

from fitness import build_fitness_snapshot
from resolve import resolve_user

REGION = os.environ.get("AWS_REGION", "us-east-1")
VAULT_KEY_ARN = os.environ["VAULT_KEY_ARN"]
DB_SECRET_ID = os.environ["DB_SECRET_ID"]

_secrets = boto3.client("secretsmanager", region_name=REGION)
_kms = boto3.client("kms", region_name=REGION)

# Module scope, so a warm invocation reuses it. Neither is a per-request fact.
_database_url: str | None = None


def database_url() -> str:
    """The connection, from Secrets Manager rather than the environment.

    **Verified against a pinned CA.** Supabase's pooler presents a *self-signed*
    chain, so `sslmode=verify-full` against the system store fails — which is
    the failure that gets "fixed" by turning verification off, leaving a
    connection carrying somebody's whole library encrypted but unauthenticated.
    `sslrootcert` points at the root Supabase publishes, which is shipped in the
    bundle: fetching it at runtime would mean trusting the network to say what
    to trust.
    """
    global _database_url
    if _database_url is None:
        secret = json.loads(_secrets.get_secret_value(SecretId=DB_SECRET_ID)["SecretString"])
        root = os.path.join(os.path.dirname(__file__), "supabase-ca.pem")
        _database_url = (
            f"postgresql://{secret['user']}:{secret['password']}"
            f"@{secret['host']}:{secret['port']}/{secret['dbname']}"
            f"?sslmode=verify-full&sslrootcert={root}"
        )
    return _database_url


def recompute_user(job: WorkerJob) -> dict[str, Any]:
    """`recompute_user` — the job `finalize_ingestion_run_v031` enqueues.

    The payload names the user and the input revision the run produced, plus the
    ontology version and the three model ids the contract binds a computation to
    — which is exactly the column list of `semantic_runs`, because this job was
    designed to open one.

    **The ontology version is read live, not taken from the payload**, and the
    schema settles it: `guard_semantic_run_contract` refuses a run whose version
    is not currently `published`, so a job queued before a version change could
    never open one against the version it names. Exactly one version is published
    at a time, and `recompute_user` exists so outputs can be rebuilt when it
    moves. The payload's `ontology_version_id` records what the job was queued
    with; the run records what it actually used.

    Scoring and embedding still do not run, so their model ids are carried and
    not honoured: a result stamped with a model that did not run would be worse
    than no result.

    **It no longer calls `project_user`, and that is the second half of `0059`.**
    Writing observations from here could never work: `guard_observation_ingestion
    _run` takes a `for key share` lock on the run, which needs `update` on
    `ingestion_runs` on top of `select`, and a worker that could update a run
    could mark somebody's capture complete. The privilege was the visible half;
    the real one is that an observation belongs to the run that captured it, and
    a worker running minutes later has no running run of its own. That is why
    projection moved into ingestion, and this call was what survived the move —
    failing every invocation with `42501` and taking the whole job down with it,
    which is how it blocked the fitness snapshot behind it.

    One consequence, unfixed and belonging elsewhere: ~1,224 music rows captured
    before `0059` still have no observation, all of them behind a single
    ingestion run left `running` from before finalization existed. They are the
    zombie-run problem rather than a projection problem, and reviving this call
    would have written their evidence into a run that will never finalize.
    """
    import psycopg
    from psycopg.rows import dict_row

    user_id = job.payload["user_id"]
    try:
        # **`prepare_threshold=None` — no prepared statements, ever.** Supabase's
        # transaction pooler routes each transaction to whichever backend is
        # free, so a statement prepared on one is absent on the next and the
        # name collides: `DuplicatePreparedStatement`, SQLSTATE `42P05`, from
        # `cursor.py` with nothing naming the pooler.
        #
        # psycopg 3 prepares automatically once a statement has run five times,
        # which is why this survived so long unset — no query here ran five
        # times in one connection until `DEMOTE_ASSERTION` arrived and ran once
        # per non-eligible concept, several hundred times a run. It then failed
        # for one account and not the other, which reads as bad data rather
        # than a driver setting.
        #
        # CLAUDE.md has asserted since the pooler was chosen that "the Lambda's
        # driver must have them off". It was a requirement nobody implemented.
        with psycopg.connect(
            database_url(), row_factory=dict_row, prepare_threshold=None
        ) as connection:
            fitness = build_fitness_snapshot(
                connection, _kms, user_id, vault_key_arn=VAULT_KEY_ARN
            )
            # **Committed separately, because they are two conclusions about two
            # sources.** A resolver failure must not roll back a fitness
            # snapshot that was correctly written — the same shape as the
            # Calendar rollback that once took a whole run's capture with it.
            connection.commit()
            # **No KMS, and no vault.** Resolution reads
            # `observations.normalized_payload`, which is already the sanitised
            # projection, so the worker's `Decrypt` stays reserved for
            # classifiers that genuinely need plaintext.
            mappings = resolve_user(connection, user_id, job.payload)
    except Exception as error:
        # **The queue is forbidden from carrying this, so the log has to.**
        # `SemanticWorker` catches a handler exception and records the stable
        # code `handler_error` and nothing else — right for a durable row that
        # must never hold plaintext, and it left the first real failure with no
        # explanation anywhere. Same shape as the ingestion endpoint's 401,
        # which said nothing to the caller *or* the operator.
        #
        # **Type, sqlstate and constraint name only — never `str(error)`.** A
        # database error quotes the offending value, and the offending value
        # here is somebody's decrypted library. §12 is explicit that no
        # plaintext may reach logs.
        diagnostic = {"error_type": type(error).__name__}
        sqlstate = getattr(error, "sqlstate", None)
        if sqlstate:
            diagnostic["sqlstate"] = sqlstate
        diag = getattr(error, "diag", None)
        for field in ("constraint_name", "table_name", "column_name"):
            value = getattr(diag, field, None) if diag else None
            if value:
                diagnostic[field] = value
        # **The one sqlstate whose message is safe to log.** `42501` is
        # "permission denied for <object>": it names a relation, a function or a
        # schema and never quotes a row, so it cannot carry a decrypted title
        # the way a constraint violation or a type error can. Without it the
        # diagnostic said `InsufficientPrivilege` and nothing else, which is
        # true and useless — it took two rounds of guessing which grant was
        # missing before this was worth adding.
        if sqlstate == "42501" and diag is not None:
            message = getattr(diag, "message_primary", None)
            if message:
                diagnostic["denied"] = message[:200]
        # **`P0001` is the second, and it is safe for a different reason.**
        # `raise_exception` is only ever raised by a function in this
        # repository, and every such message is a hand-written string naming a
        # schema object, a gate or a count — `YouTube mapping semantic kind is
        # not approved for this run`, `user assertion predicate % must be a
        # user_claim`. Where they interpolate at all they interpolate
        # vocabulary: a predicate key, a source code, a number. None reads a
        # payload, which is what makes this different from the constraint
        # violations the rule above exists to keep out of logs.
        #
        # **It is a convention rather than a mechanism, and that is the risk.**
        # A guard written later that interpolates a title would put it here.
        # Worth the trade because the alternative is measured: an opaque P0001
        # cost two long rounds of reading trigger definitions in one afternoon,
        # once for a job pinned to a retired scorer and once for a refused
        # mapping — and in both cases the message would have said it outright.
        if sqlstate == "P0001" and diag is not None:
            message = getattr(diag, "message_primary", None)
            if message:
                diagnostic["refused"] = message[:200]
        frame = error.__traceback__
        while frame and frame.tb_next:
            frame = frame.tb_next
        if frame:
            diagnostic["at"] = (
                f"{os.path.basename(frame.tb_frame.f_code.co_filename)}"
                f":{frame.tb_lineno}"
            )
        print(json.dumps({"handler_failed": diagnostic}))
        raise

    # **The result is a closed vocabulary, not free-form JSON**, and the first
    # version of this returned `{"projected": {…}, "input_revision": …}` and was
    # refused by `guard_worker_job_contract_v03`. That refusal is the contract
    # working: `worker_job_result_is_safe_v03` allows at most sixteen keys, each
    # drawn from a fixed set of id, count, boolean and status names, and nothing
    # else — which is §12's "no plaintext in queue payloads" enforced
    # structurally rather than by anyone remembering. A handler that could put
    # arbitrary strings in a durable row is a handler that could put a decrypted
    # calendar title there.
    result = {
        "status": "succeeded",
        "item_count": fitness["read"],
        "created_count": fitness["written"],
        "skipped_count": fitness["unreadable"],
        "changed": fitness["written"] > 0,
        "candidate_count": fitness["candidates"],
        "abstained": bool(fitness.get("abstained")),
        "mapping_count": mappings["mappings"],
        **({"semantic_run_id": mappings["semantic_run_id"]}
           if mappings.get("semantic_run_id") else {}),
    }
    # Absent rather than null when there is no snapshot: the vocabulary types
    # this key as a uuid, and a null would be refused for the whole result.
    if fitness.get("snapshot_id"):
        result["fitness_snapshot_id"] = fitness["snapshot_id"]
    return result


DUE_SIBLING_MINTS = """
select id, user_id::text as user_id
  from semantic_private.worker_jobs
 where job_type = 'mint_vocabulary'
   and status = 'queued'
   and available_at <= now()
   and id <> %(claimed)s::uuid
 for update skip locked
"""

SETTLE_SIBLING_MINTS = """
update semantic_private.worker_jobs
   set status = 'succeeded'
 where id = any(%(ids)s::uuid[])
   and status = 'queued'
"""


def mint_vocabulary(job: WorkerJob) -> dict[str, Any]:
    """`mint_vocabulary` — the job a distillation arms, two quiet minutes later.

    **It mints for everybody currently due, not only the user who armed it.**
    Publishing an ontology version copies the whole ontology forward and puts the
    version into every user's run identity, so each publish forces a fresh run
    for every account. One version per user per distillation is therefore
    O(users²) across a signup wave. Because the mint outlives the two-minute
    window, other users fall due while it runs and get swept into the same pass —
    the batching is a consequence of the timing rather than a policy bolted on.

    **Siblings are settled after the mint commits, never before.** If the settle
    fails they stay `queued` and are minted again next pass, which is harmless:
    an artist already minted is linked rather than duplicated. Marking them first
    would record work that had not happened.

    **A missing developer token is `no_op`, not a failure.** `CatalogueUnavailable`
    means nobody configured the credential; retrying cannot fix that and a dead
    job would read as a defect. An *expired* token raises from the fetch and is a
    real error, which is the distinction worth keeping — silently not enriching
    is the failure mode this whole exercise exists to remove.
    """
    import psycopg
    from psycopg.rows import dict_row

    from catalogue import CatalogueUnavailable, mint_for

    with psycopg.connect(
        database_url(), row_factory=dict_row, prepare_threshold=None
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(DUE_SIBLING_MINTS, {"claimed": job.id})
            siblings = cursor.fetchall()

        users = [job.payload["user_id"]]
        users += [row["user_id"] for row in siblings if row["user_id"]]
        users = list(dict.fromkeys(users))

        try:
            receipt = mint_for(connection, users)
        except CatalogueUnavailable as reason:
            connection.rollback()
            print(json.dumps({"mint_vocabulary": {"declined": str(reason)}}))
            return {"status": "no_op", "item_count": 0}

        connection.commit()

        if siblings:
            with connection.cursor() as cursor:
                cursor.execute(
                    SETTLE_SIBLING_MINTS,
                    {"ids": [row["id"] for row in siblings]},
                )
            connection.commit()

    print(json.dumps({"mint_vocabulary": receipt}))
    return {
        "status": "succeeded" if receipt.get("published") else "no_op",
        "item_count": int(receipt.get("isrcs_looked_up", 0)),
        "created_count": int(receipt.get("minted", 0)),
        "updated_count": int(receipt.get("linked", 0)),
        "skipped_count": int(receipt.get("refused", 0)),
        "changed": bool(receipt.get("published")),
    }


def handler(event, context):  # noqa: ANN001 - Lambda signature
    queue = PostgresJobQueue(
        database_url(),
        worker_id=f"lambda:{uuid.uuid4()}",
        # **Required, with no default, and the reason is in the package.**
        # Upstream hardcoded `private.worker_jobs`; in this app `private` is a
        # real, unrelated schema holding the push secret and the collaborator
        # list, so a missed rename would address a live namespace rather than an
        # empty one.
        schema="semantic_private",
    )
    worker = SemanticWorker(queue, handlers={
        "recompute_user": recompute_user,
        # Registered here or the job is claimed and marked `dead` with
        # `no_handler:mint_vocabulary` — which is why `0176` must not be applied
        # before this ships.
        "mint_vocabulary": mint_vocabulary,
    })
    outcome = worker.run_once()
    print(json.dumps({"worker": outcome}))
    return outcome
