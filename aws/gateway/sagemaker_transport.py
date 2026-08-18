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

Nothing is written to the log. A provider error string can quote the input it
choked on, so the status and the exception type are all that survive.
"""
from __future__ import annotations

import json
import time
import uuid
from typing import Any

from written_ontology import gateway


class SageMakerAsyncTransport:
    """One asynchronous call, polled to completion and then swept."""

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
                InferenceId=uuid.uuid4().hex)
        except Exception as failure:  # noqa: BLE001 - classified, never quoted
            name = type(failure).__name__
            if "Throttling" in name or "TooManyRequests" in name:
                raise gateway.RateLimited(name) from None
            raise RuntimeError(name) from None

        return self._await(self._client("s3"),
                           _key_of(started.get("OutputLocation")),
                           _key_of(started.get("FailureLocation")),
                           timeout_s)

    def _await(self, s3, output_key: str | None, failure_key: str | None,
               timeout_s: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if failure_key and _exists(s3, self._bucket, failure_key):
                # The failure object is provider text too, and the same rule
                # applies to it: deleting it is not optional.
                _delete_or_raise(s3, self._bucket, failure_key)
                raise RuntimeError("endpoint_failure")
            if output_key and _exists(s3, self._bucket, output_key):
                raw = s3.get_object(Bucket=self._bucket, Key=output_key)["Body"].read()
                # Deleted before it is parsed, and a failure here withholds the
                # answer rather than being logged and stepped over.
                _delete_or_raise(s3, self._bucket, output_key)
                return _read(raw)
            time.sleep(self._poll)
        raise TimeoutError("the endpoint did not answer in time")


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
