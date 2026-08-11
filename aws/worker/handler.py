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
    four model ids the contract binds a computation to. Only the user is used
    today. Scoring, resolution and embedding are the models' work and come
    after, which is why their ids are carried but not honoured — a result
    stamped with a model that did not run would be worse than no result.

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
        with psycopg.connect(database_url(), row_factory=dict_row) as connection:
            fitness = build_fitness_snapshot(
                connection, _kms, user_id, vault_key_arn=VAULT_KEY_ARN
            )
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
    }
    # Absent rather than null when there is no snapshot: the vocabulary types
    # this key as a uuid, and a null would be refused for the whole result.
    if fitness.get("snapshot_id"):
        result["fitness_snapshot_id"] = fitness["snapshot_id"]
    return result


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
    worker = SemanticWorker(queue, handlers={"recompute_user": recompute_user})
    outcome = worker.run_once()
    print(json.dumps({"worker": outcome}))
    return outcome
