"""The Lambda entrypoint. Four lines of routing and no decisions.

The gateway is a container image invoked directly by `written-semantic-worker`
over IAM: no function URL, no API Gateway, no public surface. So the event *is*
the request, and `dispatch` is the same function the local harness calls.
"""
from __future__ import annotations

import os
from typing import Any

from written_ontology import gateway, gateway_http

from server import build_deployment  # noqa: E402 - flat Lambda layout

_BREAKER = gateway.CircuitBreaker()


def _transport():
    """None until an endpoint is configured, which is correct while off."""
    endpoint = os.environ.get("WRITTEN_SAGEMAKER_ENDPOINT")
    bucket = os.environ.get("WRITTEN_ASYNC_BUCKET")
    if not endpoint or not bucket:
        return None
    from sagemaker_transport import SageMakerAsyncTransport  # noqa: PLC0415
    return SageMakerAsyncTransport(
        endpoint, bucket, prefix=os.environ.get("WRITTEN_ASYNC_PREFIX", "async"),
        kms_key_id=os.environ.get("WRITTEN_ASYNC_KMS_KEY_ID") or None,
        tickets=_tickets())


def _tickets():
    """None without a table, which is honest rather than convenient.

    A gateway with no ticket store still submits once and still refuses to
    resubmit; it simply cannot offer continuation. Falling back to a second
    submission would be the behaviour the store exists to remove.
    """
    table = os.environ.get("WRITTEN_TICKET_TABLE")
    if not table:
        return None
    from ticket_store import TicketStore  # noqa: PLC0415
    return TicketStore(table)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    status, body = gateway_http.dispatch(
        event or {}, deployment=build_deployment(), transport=_transport(),
        breaker=_BREAKER)
    # **`status_code`, not `status`.** The status travels in the payload because
    # there is no HTTP here — a direct invoke returns a document — and the first
    # version merged it under `status`, which `health` already uses for its own
    # "ok". The envelope silently lost to the body and every health check
    # answered without a code. A key that two writers may claim is not an
    # envelope.
    return {"status_code": status, **body}
