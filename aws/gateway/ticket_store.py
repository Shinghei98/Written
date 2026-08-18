"""Where an accepted-but-unfinished inference is remembered.

**A ticket is the difference between waiting and losing the work.** The
transport submits once and polls; when polling runs out the job still exists,
and without somewhere to write down *which* job, the only thing a caller can do
is submit another one — which is the defect the derived inference id was meant
to make visible rather than the one it was meant to fix. Starting a
scaled-to-zero g6e takes minutes; a gateway that polls for a bounded time and
then forgets would abandon every first request of the day, leave its answer in a
bucket for the lifecycle rule to remove, and bill for the GPU that produced it.

## What is stored, and what is deliberately not

The request id, the inference id, the two object keys, and when it was made.
**No fields, no titles, no user id, no account.** A ticket is a claim about a
job, not about a person — which is what lets it live in a table with a short TTL
rather than under the vault's erasure machinery. The request id is already
defined as opaque and carrying nothing about whose request it is, and that is
exactly the property being relied on here.

## TTL, and why it is not the retention story

The rows expire because a ticket nobody collected is worthless, not because the
data is sensitive. The answer's retention is handled where it always was: read
once, deleted before parsing, and a failed delete withholds the result.

## Absent by choice

`None` is a valid store. Without a table the transport still submits once and
still refuses to resubmit; it simply cannot offer continuation, which is the
honest behaviour for a deployment that has not configured one — rather than
falling back to the resubmission this exists to prevent.
"""
from __future__ import annotations

import time
from typing import Any


class TicketStore:
    """DynamoDB, because the thing that needs to survive is a Lambda invocation."""

    def __init__(self, table: str, ttl_seconds: int = 86400,
                 client: Any | None = None,
                 clock=time.time) -> None:
        self._table = table
        self._ttl = ttl_seconds
        self._client = client
        self._clock = clock

    def _dynamo(self):
        if self._client is None:
            import boto3  # noqa: PLC0415 - the Lambda base image carries it
            self._client = boto3.client("dynamodb")
        return self._client

    def put(self, request_id: str, inference_id: str,
            output_key: str | None, failure_key: str | None) -> None:
        item = {
            "request_id": {"S": request_id},
            "inference_id": {"S": inference_id},
            "submitted_at": {"N": str(int(self._clock()))},
            "expires_at": {"N": str(int(self._clock()) + self._ttl)},
        }
        if output_key:
            item["output_key"] = {"S": output_key}
        if failure_key:
            item["failure_key"] = {"S": failure_key}
        self._dynamo().put_item(TableName=self._table, Item=item)

    def get(self, request_id: str) -> dict[str, str] | None:
        answer = self._dynamo().get_item(
            TableName=self._table, Key={"request_id": {"S": request_id}},
            ConsistentRead=True)
        row = answer.get("Item")
        if not row:
            return None
        return {name: value.get("S") or value.get("N")
                for name, value in row.items()}

    def delete(self, request_id: str) -> None:
        """Collected, so there is nothing left to continue.

        A failure here is not raised: the ticket is bookkeeping, and a row that
        outlives its job costs a wasted lookup and expires on its own. The
        deletion that must never be swallowed is the answer's, and that one
        raises `RetentionFailure`.
        """
        try:
            self._dynamo().delete_item(
                TableName=self._table, Key={"request_id": {"S": request_id}})
        except Exception:  # noqa: BLE001 - see the docstring
            pass
