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

from observations import project_user

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
    today: this projects vault rows into observations and stops there. Scoring,
    resolution and embedding are the models' work and come after, which is why
    their ids are carried but not honoured — a result stamped with a model that
    did not run would be worse than no result.
    """
    import psycopg
    from psycopg.rows import dict_row

    user_id = job.payload["user_id"]
    with psycopg.connect(database_url(), row_factory=dict_row) as connection:
        counts = project_user(connection, _kms, user_id, vault_key_arn=VAULT_KEY_ARN)

    # Returned, so it lands in `worker_jobs.result` where an operator can read
    # it. Integers only — the one place a decrypted title could escape into a
    # durable row is here, and §12 is explicit that no plaintext may reach a
    # queue payload.
    return {"projected": counts, "input_revision": job.payload.get("input_revision")}


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
