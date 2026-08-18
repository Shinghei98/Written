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

    # -- the whole act ----------------------------------------------------

    def propose(self, *, user_id: str, items: list[dict[str, Any]],
                request_id: str, source_profile: str,
                resume: bool = False) -> dict[str, Any]:
        """Ask the model, record what happened, hand back the lineage.

        Returns `{"invocation_id", "lineage", "items"}` where `lineage` is one
        row per requested item — **including the ones that failed**. A model
        that answered two of three produces three rows, one saying so; a gap
        would be indistinguishable from a crash mid-write, which is the rule
        `record_model_invocation` enforces and this respects rather than
        rediscovers.
        """
        route = "v1/semantic/collect" if resume else "v1/semantic/extract"
        request: dict[str, Any] = {"route": route, "request_id": request_id,
                                   "items": items}
        if not resume:
            request["source_profile"] = source_profile

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
                # **`missing_item` for an item the model did not answer**, not
                # an absent row: a gap cannot be told apart from a crash.
                "outcome": (outcome if answered is not None
                            else ("missing_item" if outcome == "succeeded"
                                  else outcome)),
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
                        "input_hash": answer.get("input_hash") or "unrecorded",
                        "model_id": answer.get("model_id") or "unrecorded",
                        "model_revision": answer.get("model_revision") or "unrecorded",
                        "prompt": answer.get("prompt_version") or "unrecorded",
                        "grammar": answer.get("grammar_version") or "unrecorded",
                        "schema": answer.get("output_schema_hash") or "unrecorded",
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
