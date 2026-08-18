"""SageMaker Asynchronous Inference, and the outputs are deleted as they are read.

Async rather than real-time because the endpoint scales to zero: a g6e.xlarge
costs money whenever it is up, and the extraction lane is bursty by nature — a
distillation arrives, a few hundred items want scoring, then nothing for hours.
`min=0, max=1` is what makes that affordable, and asynchronous invocation is the
only mode that permits it.

## The request never becomes a file

`InvokeEndpointAsync` requires only `EndpointName`: `InputLocation` is optional
and `Body` is accepted inline. The first version of this module wrote the
request to S3 and passed a location, on the assumption that async inference had
no inline path — it does, and the difference is one whole retention surface that
now does not exist. A request is somebody's title, and the best handling of a
file is not to create it.

## The output is a file, and failing to delete it withholds the result

Only the answer comes back through S3. It is read once and deleted **before it
is parsed**, so a malformed body cannot be the reason a file survives.

**If that delete fails the call has not succeeded.** The model answered, the
mentions may be valid, and they are withheld anyway: committing semantics
derived from text we cannot show we stopped holding is the trade this refuses.
An earlier version swallowed the failure, reasoning that a delete which raised
would turn a successful extraction into a failure. That is precisely what it
should do. `retention_failed` is the outcome (`0242`), and the bucket's one-day
lifecycle rule is a backstop for a process that died rather than a licence to
proceed past this.

## Submitted once, and a poll that runs out is not a licence to submit again

The first version minted `InferenceId=uuid.uuid4().hex` **inside** the call, so
every retry was a fresh submission. `timeout` is not in the gateway's
`_NOT_RETRYABLE` set, which made that the ordinary path rather than an edge
case: one slow answer became two inferences on an endpoint deliberately capped
at a single instance, the second queued behind the first, and the first
answer landed in S3 with nobody left to read it or delete it. A module that
refuses to swallow a delete failure was leaking objects through its own retry.

So the identifier is **derived from the request** rather than generated, and
submission is separated from collection:

- `submit` enqueues and returns an `InferenceTicket`.
- `collect` polls a ticket and never enqueues anything.
- `complete` is the two in sequence, for a caller that wants one call.

When polling runs out **after** the work was accepted, the failure raised is
`InferenceInFlight`, carrying the ticket. That is a different fact from "the
endpoint could not be reached", and the gateway treats it as terminal for the
attempt: the work exists, so asking for it again is not a retry, it is a second
job. A caller holding the ticket can `collect` it later without resubmitting.

The residual is honest and small: an abandoned ticket leaves an output object
that no one deletes, and the bucket's one-day lifecycle rule is what removes it.
That is the backstop this module already names — a process that died — rather
than something the happy path walks into twice per slow answer.

Nothing is written to the log. A provider error string can quote the input it
choked on, so the status and the exception type are all that survive.
"""
from __future__ import annotations

import dataclasses
import json
import time
from typing import Any

from written_ontology import gateway


@dataclasses.dataclass(frozen=True)
class InferenceTicket:
    """Work that has been accepted, and where its answer will appear.

    Returned by `submit` and carried by `InferenceInFlight`, so a caller that
    ran out of patience can collect the same job later instead of starting a
    second one. It holds no request content — an id and two object keys.
    """

    inference_id: str
    output_key: str | None
    failure_key: str | None


def _inference_id(payload: dict[str, Any]) -> str:
    """The request's own id, never a generated one.

    `input.request_id` is defined by the request schema as opaque, unique to the
    request and carrying nothing about whose it is — which is exactly what an
    inference id must be, so minting a second identifier alongside it would add
    a handle without adding a fact. Deriving it also makes resubmission
    *visible*: two jobs with one id are the same work twice, and two jobs with
    two random ids are indistinguishable from two pieces of work.

    SageMaker accepts up to 64 characters; the schema bounds `request_id` to the
    same 64 and to `[A-Za-z0-9_-]`, so anything the validator passed fits here.
    """
    # **`input.request_id`, because that is where the envelope puts it.** The
    # first version of this function read the top level, which is where the
    # *request document* carries it — but `_serialise` wraps that document under
    # `input` alongside the model, the sampling parameters and the response
    # format. So every real call refused with `contract_mismatch` before
    # reaching SageMaker, and the tests did not see it because they passed a
    # hand-written payload rather than the envelope the gateway actually builds.
    # They now build it the same way `extract` does.
    request_id = (payload.get("input") or {}).get("request_id")
    if not isinstance(request_id, str) or not request_id:
        # Never fall back to a random id: that is the defect this replaced.
        raise gateway.GatewayRefusal(
            "contract_mismatch", "the request carries no request_id to submit under")
    return request_id


class SageMakerAsyncTransport:
    """One asynchronous call: submitted once, collected separately."""

    def __init__(self, endpoint_name: str, bucket: str, prefix: str = "async",
                 kms_key_id: str | None = None, poll_interval_s: float = 1.0,
                 clients: dict[str, Any] | None = None) -> None:
        self._endpoint = endpoint_name
        self._bucket = bucket
        self._prefix = prefix.strip("/")
        self._kms_key_id = kms_key_id
        self._poll = poll_interval_s
        self._clients = clients or {}

    def _client(self, name: str):
        if name not in self._clients:
            import boto3  # noqa: PLC0415 - the Lambda base image carries it
            self._clients[name] = boto3.client(name)
        return self._clients[name]

    def complete(self, payload: dict[str, Any], timeout_s: float) -> dict[str, Any]:
        """Submit, then collect. The two halves are separable on purpose."""
        return self.collect(self.submit(payload, timeout_s), timeout_s)

    def submit(self, payload: dict[str, Any], timeout_s: float) -> InferenceTicket:
        """Enqueue exactly one job and say where its answer will appear.

        Everything that can fail *before* the endpoint accepts the work fails
        here, where retrying is free because nothing was enqueued.
        """
        runtime = self._client("sagemaker-runtime")
        body = json.dumps(payload, ensure_ascii=False).encode()

        try:
            # **Inline.** No input object, so no input to delete and none to
            # leak if this process dies between the put and the invoke.
            started = runtime.invoke_endpoint_async(
                EndpointName=self._endpoint,
                Body=body,
                ContentType="application/json",
                InvocationTimeoutSeconds=int(timeout_s),
                InferenceId=_inference_id(payload))
        except gateway.GatewayRefusal:
            raise
        except Exception as failure:  # noqa: BLE001 - classified, never quoted
            name = type(failure).__name__
            if "Throttling" in name or "TooManyRequests" in name:
                raise gateway.RateLimited(name) from None
            raise RuntimeError(name) from None

        return InferenceTicket(
            inference_id=started.get("InferenceId") or _inference_id(payload),
            output_key=_key_of(started.get("OutputLocation")),
            failure_key=_key_of(started.get("FailureLocation")))

    def collect(self, ticket: InferenceTicket, timeout_s: float) -> dict[str, Any]:
        """Poll a ticket. **Never enqueues anything.**

        Running out of time here raises `InferenceInFlight` rather than
        `TimeoutError`, because the two are different facts: one means the work
        exists and has not finished, the other means it may never have started.
        Only the second is safe to answer with another submission.
        """
        s3 = self._client("s3")
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if ticket.failure_key and _exists(s3, self._bucket, ticket.failure_key):
                # The failure object is provider text too, and the same rule
                # applies to it: deleting it is not optional.
                _delete_or_raise(s3, self._bucket, ticket.failure_key)
                raise RuntimeError("endpoint_failure")
            if ticket.output_key and _exists(s3, self._bucket, ticket.output_key):
                raw = s3.get_object(
                    Bucket=self._bucket, Key=ticket.output_key)["Body"].read()
                # Deleted before it is parsed, and a failure here withholds the
                # answer rather than being logged and stepped over.
                _delete_or_raise(s3, self._bucket, ticket.output_key)
                return _read(raw)
            time.sleep(self._poll)
        raise gateway.InferenceInFlight(ticket)


def _read(raw: bytes) -> dict[str, Any]:
    body = json.loads(raw)
    choice = (body.get("choices") or [{}])[0]
    content = choice.get("message", {}).get("content")
    return {
        "finish_reason": choice.get("finish_reason"),
        "output_tokens": (body.get("usage") or {}).get("completion_tokens"),
        "body": json.loads(content) if isinstance(content, str) else content,
    }


def _key_of(location: str | None) -> str | None:
    if not location or not location.startswith("s3://"):
        return None
    return location.split("/", 3)[3]


def _exists(s3, bucket: str, key: str) -> bool:
    try:
        s3.head_object(Bucket=bucket, Key=key)
    except Exception:  # noqa: BLE001 - absence is the common case, not an error
        return False
    return True


def _delete_or_raise(s3, bucket: str, key: str | None) -> None:
    """Delete, or refuse the whole call.

    The version this replaced swallowed the error and let the extraction
    succeed. That committed semantics derived from text still sitting in a
    bucket, with a lifecycle rule as the only thing that would ever remove it —
    a retention promise kept by a schedule nobody was watching.
    """
    if not key:
        return
    try:
        s3.delete_object(Bucket=bucket, Key=key)
    except Exception as failure:  # noqa: BLE001 - the type, never the message
        raise gateway.RetentionFailure(type(failure).__name__) from None
