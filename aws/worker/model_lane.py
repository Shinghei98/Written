"""The model lane: a second identity, and the only thing that may record a call.

**Why this is a separate module and a separate credential.** `0241` asserts that
`semantic_worker` cannot execute `record_model_invocation`, and `0243` asserts it
cannot read invocation items either. The deterministic worker is the process
that wants to write a mention and is precisely the process forbidden from
recording the call that would justify one — the same shape as `messages`, where
the only client positioned to write the row is the one client forbidden to.

So the lane is not a function the worker calls into with its own connection. It
is an identity:

    semantic_model_worker   invoke the gateway, record the call and its items,
                            read the lineage back
    semantic_worker         write the mention, naming an item it did not create

The handoff is a **value in memory**, never a shared credential and never a
`SET ROLE`. Two secrets, two connections. The worker never learns the model
lane's DSN and could not use it if it did — `0240` and `0243` assert the two
roles are not members of one another, so neither can become the other.

## What travels, and what does not

The gateway receives titles. That is the point of it, and the request schema is
an allowlist so nothing else can travel by accident. What comes *back* into this
process is validated items and counts; the response body never reaches the
database, because `model_invocation_items` has no text column and `20.1` is why.

## Continuation

A first call to a scaled-to-zero endpoint will not finish inside one invocation.
The gateway answers `timeout` with a `resume` block naming the request id, and
this lane returns that rather than treating it as a failure: the work exists and
asking again would start a second job. The caller re-enters with the same
request id and collects.
"""
from __future__ import annotations

import json
import os
from typing import Any

GATEWAY_FUNCTION = os.environ.get("WRITTEN_GATEWAY_FUNCTION",
                                  "written-semantic-gateway")
MODEL_DB_SECRET_ID = os.environ.get("WRITTEN_MODEL_DB_SECRET_ID", "")


class LaneUnavailable(RuntimeError):
    """The lane cannot run, and the caller must not pretend it did.

    Raised for a missing credential or a missing gateway — never for a model
    that answered badly, which is an outcome and is recorded as one.
    """


class InFlight(RuntimeError):
    """Accepted, unfinished. Carries the request id to come back with."""

    def __init__(self, request_id: str) -> None:
        super().__init__("the endpoint accepted the work and has not answered")
        self.request_id = request_id


def _required(answer: dict[str, Any], field: str) -> str:
    """Provenance the gateway must supply, or the call is not recordable."""
    value = answer.get(field)
    if not value:
        raise LaneUnavailable(
            f"the gateway answered without {field}; the call cannot be recorded")
    return str(value)


def _item_outcome(answered: dict[str, Any] | None, call_outcome: str) -> str:
    """The item's own verdict, not the call's.

    **An abstention is not a success.** `mention_extract_v2` gives each item a
    `status`, and a model that looked at a title and declined to name anything
    has said something specific — `semantic_abstention` is its own outcome in
    the closed vocabulary precisely so it is not counted as extraction that
    happened to find nothing. Recording every item of a 200 as `succeeded`
    erased that distinction, and it is the distinction the whole shadow
    measurement is about.

    An item the model did not answer at all is `missing_item` rather than an
    absent row, because a gap cannot be told apart from a crash mid-write.
    """
    if answered is None:
        return "missing_item" if call_outcome == "succeeded" else call_outcome
    if call_outcome != "succeeded":
        return call_outcome
    if answered.get("status") == "abstained":
        return "semantic_abstention"
    return "succeeded"


class ModelLane:
    """One call to the gateway, recorded under the identity that may record it."""

    def __init__(self, lambda_client: Any | None = None,
                 secrets_client: Any | None = None,
                 connect: Any | None = None,
                 function_name: str = GATEWAY_FUNCTION,
                 secret_id: str = MODEL_DB_SECRET_ID) -> None:
        self._lambda = lambda_client
        self._secrets = secrets_client
        self._connect = connect
        self._function = function_name
        self._secret_id = secret_id
        self._dsn: str | None = None

    # -- the gateway ------------------------------------------------------

    def _client(self):
        if self._lambda is None:
            import boto3  # noqa: PLC0415
            self._lambda = boto3.client("lambda")
        return self._lambda

    def call_gateway(self, request: dict[str, Any]) -> dict[str, Any]:
        """Invoke directly over IAM. No URL, no API Gateway, no public surface."""
        answer = self._client().invoke(
            FunctionName=self._function,
            InvocationType="RequestResponse",
            Payload=json.dumps(request).encode())
        body = json.loads(answer["Payload"].read() or b"{}")
        if answer.get("FunctionError"):
            # The gateway refuses in its body; a FunctionError means it did not
            # get that far, which is infrastructural rather than an outcome.
            raise LaneUnavailable(str(answer.get("FunctionError")))
        return body

    # -- the credential ---------------------------------------------------

    def _model_dsn(self) -> str:
        """`semantic_model_worker`, from its own secret.

        Deliberately not derived from the worker's DSN with a different user:
        the two are separate secrets so that rotating or revoking one does not
        touch the other, and so that nothing in this file can be pointed at the
        deterministic role by editing a single string.
        """
        if not self._secret_id:
            raise LaneUnavailable("no model-lane database credential is configured")
        if self._dsn is None:
            if self._secrets is None:
                import boto3  # noqa: PLC0415
                self._secrets = boto3.client("secretsmanager")
            secret = json.loads(
                self._secrets.get_secret_value(
                    SecretId=self._secret_id)["SecretString"])
            root = os.path.join(os.path.dirname(__file__), "supabase-ca.pem")
            self._dsn = (
                f"postgresql://{secret['user']}:{secret['password']}"
                f"@{secret['host']}:{secret['port']}/{secret['dbname']}"
                f"?sslmode=verify-full&sslrootcert={root}")
        return self._dsn

    def _open(self):
        if self._connect is not None:
            return self._connect(self._model_dsn())
        import psycopg  # noqa: PLC0415
        from psycopg.rows import dict_row  # noqa: PLC0415

        # `prepare_threshold=None` for the same reason the worker sets it: the
        # transaction pooler routes each transaction to whichever backend is
        # free, so a prepared name collides on the second call.
        return psycopg.connect(self._model_dsn(), row_factory=dict_row,
                               prepare_threshold=None)

    # -- proving the credential -------------------------------------------

    #: What the lane must be able to call, by bare name. **Never a signature.**
    #: `0241` writes `record_model_invocation`'s seventeen argument types out in
    #: full, and a second copy here would be a second thing to edit when the
    #: function changes and the first thing forgotten — so the probe looks the
    #: function up in `pg_proc` and asks about whatever it finds.
    PROBE_MUST_EXECUTE = ("record_model_invocation", "model_invocation_lineage")

    #: What it must not be able to write. `0239`'s list, which is the whole of
    #: why this is a second role rather than a second connection string: if the
    #: model lane can reach these directly, the mention guard is decoration.
    PROBE_MUST_NOT_WRITE = (
        "observation_mentions", "mention_resolutions", "provisional_entities",
        "user_term_candidates", "candidate_support_links", "review_items",
        "review_events", "review_exposures", "user_term_suppressions",
        "user_suppressions", "user_assertions", "observations",
        "raw_source_records",
    )

    def probe(self) -> dict[str, Any]:
        """Connect as the model lane, prove what it is, and write nothing.

        **A credential is only checked by using it.** Everything else the
        deployment verifier can see — that a secret exists, that it holds a
        value, that a policy is attached — is true of a password for an identity
        that cannot log in, which is exactly the state this lane shipped in.

        So this opens the real connection, with the real secret, through
        `_model_dsn` and `_open` rather than a second copy of either. What it
        must never do is the rest of `propose`: no gateway call, no invocation
        row, nothing that a run would later have to explain. It reads the
        catalogue, **rolls back**, and returns.

        **A refusal is data.** Every check comes back as a row rather than an
        exception, so the caller prints a table instead of a stack trace and a
        failing deployment says which of six things is wrong rather than the
        first. Only an inability to *ask at all* raises, and that is
        `LaneUnavailable` for a missing credential, as everywhere else here.
        """
        # **Resolved before a driver is reached for**, so "no credential is
        # configured" refuses as itself rather than as whatever `_open` happens
        # to touch first. It is the most likely finding on a fresh deployment
        # and the one a verifier must be able to state plainly.
        self._model_dsn()

        checks: list[dict[str, Any]] = []

        def record(name: str, ok: bool, detail: str) -> None:
            checks.append({"check": name, "ok": bool(ok), "detail": detail})

        with self._open() as connection:
            with connection.cursor() as cursor:
                cursor.execute("select current_user as who, "
                               "current_database() as db, "
                               "inet_server_addr() is not null as networked")
                identity = cursor.fetchone()
                who = identity["who"]
                # **The whole point.** A pooler authenticates a username and
                # assumes a role behind it; connecting proves the password, and
                # only this proves it landed on the identity the grants were
                # written for.
                record("current_user is semantic_model_worker",
                       who == "semantic_model_worker",
                       f"connected as {who} to {identity['db']}")

                cursor.execute(
                    "select p.proname, p.oid::regprocedure::text as signature, "
                    "       has_function_privilege(current_user, p.oid, 'EXECUTE') as may "
                    "  from pg_proc p "
                    "  join pg_namespace n on n.oid = p.pronamespace "
                    " where n.nspname = 'semantic_private' "
                    "   and p.proname = any(%s)",
                    (list(self.PROBE_MUST_EXECUTE),))
                found = {row["proname"]: row for row in cursor.fetchall()}
                for name in self.PROBE_MUST_EXECUTE:
                    row = found.get(name)
                    if row is None:
                        # Absent is not permitted-and-missing: a lane that
                        # cannot find the function it exists to call is as
                        # broken as one refused execute on it.
                        record(f"may execute {name}", False,
                               "no such function in semantic_private")
                    else:
                        record(f"may execute {name}", row["may"], row["signature"])

                cursor.execute(
                    "select c.relname, "
                    "       has_table_privilege(current_user, c.oid, 'INSERT') as ins, "
                    "       has_table_privilege(current_user, c.oid, 'UPDATE') as upd "
                    "  from pg_class c "
                    "  join pg_namespace n on n.oid = c.relnamespace "
                    " where n.nspname = 'semantic_private' "
                    "   and c.relkind in ('r', 'p') "
                    "   and c.relname = any(%s)",
                    (list(self.PROBE_MUST_NOT_WRITE),))
                writable = [row["relname"] for row in cursor.fetchall()
                            if row["ins"] or row["upd"]]
                record("writes nothing it is forbidden", not writable,
                       f"can write {sorted(writable)}" if writable
                       else f"refused on all {len(self.PROBE_MUST_NOT_WRITE)}")

            # **Explicitly, and not because the reads needed it.** Leaving the
            # `with` block commits, and a probe whose safety rests on having
            # happened to run only selects is one statement away from not being
            # a probe.
            connection.rollback()

        return {"probe": "model_lane",
                "ok": all(check["ok"] for check in checks),
                "checks": checks}

    # -- the whole act ----------------------------------------------------

    def propose(self, *, user_id: str, items: list[dict[str, Any]],
                request_id: str, source_profile: str) -> dict[str, Any]:
        """Ask the model, record what happened, hand back the lineage.

        Returns `{"invocation_id", "lineage", "items"}` where `lineage` is one
        row per requested item — **including the ones that failed**. A model
        that answered two of three produces three rows, one saying so; a gap
        would be indistinguishable from a crash mid-write, which is the rule
        `record_model_invocation` enforces and this respects rather than
        rediscovers.
        """
        # **One route, always.** There is no resume flag: the transport returns
        # the existing ticket when one is recorded under this request id, so a
        # second call with the same id collects rather than submits. A flag
        # would have to travel in the job payload, which `0208` forbids, and
        # would be a second way of expressing something the ticket already says.
        request: dict[str, Any] = {"route": "v1/semantic/extract",
                                   "request_id": request_id,
                                   "source_profile": source_profile,
                                   "items": items}

        answer = self.call_gateway(request)
        status = answer.get("status_code")

        if status != 200:
            outcome = answer.get("outcome") or "provider_error"
            resume_block = answer.get("resume")
            if resume_block:
                # The work exists. Recording a failed call here would file a
                # refusal against an inference that may yet succeed, and the
                # closed vocabulary has no word for "still running" because it
                # describes what happened rather than what is happening.
                raise InFlight(resume_block["request_id"])
            # **An open breaker is unavailability, never an outcome.** Nothing
            # was submitted — the gateway refused before touching the transport
            # — so recording an invocation would file provenance for a call
            # that never happened, and completing the job would consume the
            # armer idempotency key that work gets once per release. That is
            # exactly what happened to the second release: five wake deferrals
            # opened the breaker, the sixth attempt recorded `circuit_open`
            # items as final, and the lane wedged. Deferral is the honest
            # answer: the breaker cools off in a minute, the work is unchanged.
            if outcome == "circuit_open":
                raise LaneUnavailable("the gateway breaker is open")
            return self._record(user_id, items, answer, outcome=outcome)

        return self._record(user_id, items, answer, outcome="succeeded")

    def _record(self, user_id: str, items: list[dict[str, Any]],
                answer: dict[str, Any], *, outcome: str) -> dict[str, Any]:
        """One transaction: the call, its items, and the lineage read back."""
        returned = {entry.get("item_index"): entry
                    for entry in (answer.get("items") or [])}

        rows = []
        for item in items:
            index = item["item_index"]
            answered = returned.get(index)
            rows.append({
                "user_id": user_id,
                "observation_id": item.get("observation_id"),
                "source_text_evidence_id": item.get("source_text_evidence_id"),
                "logical_extraction_key": item["logical_extraction_key"],
                "outcome": _item_outcome(answered, outcome),
                "mention_count": len(answered.get("mentions", [])) if answered else 0,
                "fingerprint_key_version": item.get("fingerprint_key_version"),
                "input_fingerprint": item.get("input_fingerprint"),
            })

        with self._open() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "select semantic_private.record_model_invocation("
                    "  %(requested)s, %(items)s::jsonb, %(input_hash)s,"
                    "  %(model_id)s, %(model_revision)s, %(prompt)s,"
                    "  %(grammar)s, %(schema)s, %(user_id)s::uuid,"
                    "  p_output_tokens => %(output_tokens)s,"
                    "  p_latency_ms => %(latency_ms)s) as invocation_id",
                    {
                        "requested": len(items),
                        "items": json.dumps(rows),
                        # **Refused rather than filled in.** These six say
                        # which model, under which prompt and schema, said this.
                        # A default would make an unprovenanced row look like a
                        # provenanced one, which is worse than no row.
                        # A refused call never built a request, so it has no
                        # input hash and does not pretend to one.
                        "input_hash": answer.get("input_hash") or "no_request_built",
                        "model_id": _required(answer, "model_id"),
                        "model_revision": _required(answer, "model_revision"),
                        "prompt": _required(answer, "prompt_version"),
                        "grammar": _required(answer, "grammar_version"),
                        "schema": _required(answer, "output_schema_hash"),
                        "user_id": user_id,
                        "output_tokens": answer.get("output_tokens"),
                        "latency_ms": answer.get("latency_ms"),
                    })
                invocation_id = cursor.fetchone()["invocation_id"]

                cursor.execute(
                    "select * from semantic_private.model_invocation_lineage(%s)",
                    (invocation_id,))
                lineage = cursor.fetchall()
            connection.commit()

        return {
            "invocation_id": str(invocation_id),
            "lineage": [dict(row) for row in lineage],
            # The validated items, for the caller to turn into mentions. They do
            # not go to the database from here — this lane holds no insert on
            # `observation_mentions`, and `0243` asserts it.
            "items": answer.get("items") or [],
        }
