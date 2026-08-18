"""SageMaker Asynchronous Inference, and the outputs are deleted as they are read.

Async rather than real-time because the endpoint scales to zero: a g6e.xlarge
costs money whenever it is up, and the extraction lane is bursty by nature — a
distillation arrives, a few hundred items want scoring, then nothing for hours.
`min=0, max=1` is what makes that affordable, and asynchronous invocation is the
only mode that permits it.

## The S3 hop is a retention surface, so it is closed immediately

Async inference works by handing the endpoint an S3 object and being handed one
back. That means **the request and the response exist as files**, and a request
is somebody's title. So:

  * the bucket is encrypted and versioning-free, because a version history of
    deleted provider text is a retention surface with no owner;
  * the input is deleted as soon as the call returns, whatever the outcome;
  * the output is read once, parsed, and deleted before it is validated — a
    validation failure must not be the reason a file survives;
  * a lifecycle rule expires anything these deletions miss, because a Lambda
    that times out mid-call is a real shape and the bucket must not accumulate.

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
        s3 = self._client("s3")
        runtime = self._client("sagemaker-runtime")
        key = f"{self._prefix}/in/{uuid.uuid4().hex}.json"
        body = json.dumps(payload, ensure_ascii=False).encode()

        put: dict[str, Any] = {
            "Bucket": self._bucket, "Key": key, "Body": body,
            "ContentType": "application/json",
        }
        if self._kms_key_id:
            put |= {"ServerSideEncryption": "aws:kms",
                    "SSEKMSKeyId": self._kms_key_id}
        else:
            put["ServerSideEncryption"] = "AES256"
        s3.put_object(**put)

        try:
            try:
                started = runtime.invoke_endpoint_async(
                    EndpointName=self._endpoint,
                    InputLocation=f"s3://{self._bucket}/{key}",
                    ContentType="application/json",
                    InvocationTimeoutSeconds=int(timeout_s))
            except Exception as failure:  # noqa: BLE001 - classified, never quoted
                name = type(failure).__name__
                if "ThrottlingException" in name or "TooManyRequests" in name:
                    raise gateway.RateLimited(name) from None
                raise RuntimeError(name) from None

            output = _key_of(started.get("OutputLocation"))
            failure_key = _key_of(started.get("FailureLocation"))
            return self._await(s3, output, failure_key, timeout_s)
        finally:
            # **The input goes whatever happened.** A refusal is not a reason to
            # leave somebody's title in a bucket.
            _delete(s3, self._bucket, key)

    def _await(self, s3, output_key: str | None, failure_key: str | None,
               timeout_s: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if failure_key and _exists(s3, self._bucket, failure_key):
                _delete(s3, self._bucket, failure_key)
                raise RuntimeError("endpoint_failure")
            if output_key and _exists(s3, self._bucket, output_key):
                raw = s3.get_object(Bucket=self._bucket, Key=output_key)["Body"].read()
                # **Deleted before it is parsed.** A malformed body must not be
                # the reason a file outlives the call that made it.
                _delete(s3, self._bucket, output_key)
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


def _delete(s3, bucket: str, key: str | None) -> None:
    if not key:
        return
    try:
        s3.delete_object(Bucket=bucket, Key=key)
    except Exception:  # noqa: BLE001
        # A sweep that raised would turn a successful extraction into a failure.
        # The bucket's lifecycle rule is the backstop, and it exists for this.
        pass
