"""The gateway's transport and its HTTP surface.

Kept apart from `gateway` deliberately: that module holds the order of the checks
and the name of every refusal, and neither needs a socket. This one holds the
socket and nothing else, so a change to the wire cannot quietly change a rule.

## Three routes, and two of them answer in every mode

    GET  /health
    GET  /v1/semantic/attestation
    POST /v1/semantic/extract

`health` and `attestation` answer whatever the lane is, because a health check
that only answered when the lane was on could not tell a disabled gateway from a
dead one, and because attesting a deployment is how `off → evaluation` is
decided — it has to work before the transition rather than after it. `extract`
refuses in `off` before it reaches a transport at all.

## Nothing here logs a body

Not the request, not the response, not a provider error message. The refusal
carries a code and a path; §20.1 is why `model_invocation_items` has no text
column and this is the same rule at the other end of the wire. WSGI is used
rather than a framework for the same reason there is no framework in this
repository: one fewer dependency whose defaults include request logging.

## Authentication is a shared secret, as `functions/push` already does it

`x-gateway-secret`, compared in constant time. The worker is the only caller and
it is not a browser; a JWT would add a validation surface for no property this
does not already have.
"""
from __future__ import annotations

import hmac
import json
import os
from typing import Any

from . import gateway
from .mention_extract_v2 import RequestItem

#: How long the model gets. `llm.gateway.timeout_ms` in the workbook.
DEFAULT_TIMEOUT_S = 30.0


class HttpModelTransport:
    """An OpenAI-compatible endpoint, reached with httpx.

    **Failures are classified, never quoted.** A provider's error string can
    contain the input it choked on, so the status code and the exception type
    are all that survive contact with this class.
    """

    def __init__(self, endpoint: str, api_key: str | None = None,
                 client: Any | None = None) -> None:
        self._endpoint = endpoint
        self._api_key = api_key
        self._client = client

    def complete(self, payload: dict[str, Any], timeout_s: float) -> dict[str, Any]:
        import httpx  # noqa: PLC0415 - only needed when a call is actually made

        client = self._client or httpx
        headers = {"content-type": "application/json"}
        if self._api_key:
            headers["authorization"] = f"Bearer {self._api_key}"
        try:
            response = client.post(self._endpoint, json=payload,
                                   headers=headers, timeout=timeout_s)
        except httpx.TimeoutException as timeout:
            raise TimeoutError("the model did not answer in time") from timeout
        except httpx.HTTPError as failure:
            raise RuntimeError(type(failure).__name__) from None

        if response.status_code == 429:
            raise gateway.RateLimited("429")
        if response.status_code >= 400:
            # The code, never the body.
            raise RuntimeError(f"http_{response.status_code}")

        body = response.json()
        choice = (body.get("choices") or [{}])[0]
        content = choice.get("message", {}).get("content")
        return {
            "finish_reason": choice.get("finish_reason"),
            "output_tokens": (body.get("usage") or {}).get("completion_tokens"),
            "body": json.loads(content) if isinstance(content, str) else content,
        }


def _unauthorized(secret: str | None, environ) -> bool:
    expected = os.environ.get("WRITTEN_GATEWAY_SECRET")
    if not expected:
        # No secret configured is a refusal, not an opening. A gateway that
        # served anyone because nobody set a variable is the failure this check
        # exists to prevent.
        return True
    return not hmac.compare_digest(secret or "", expected)


def application(environ, start_response, *, deployment=None, transport=None,
                breaker=None):
    """A WSGI app over the three routes.

    Framework-free on purpose. The routing is four lines; a framework would add
    a dependency whose defaults include logging the thing this must not log.
    """
    path = environ.get("PATH_INFO", "")
    method = environ.get("REQUEST_METHOD", "GET")

    def reply(status: str, body: dict[str, Any]):
        payload = json.dumps(body).encode()
        start_response(status, [("content-type", "application/json"),
                                ("content-length", str(len(payload)))])
        return [payload]

    if path == "/health" and method == "GET":
        return reply("200 OK", gateway.health())

    if path == "/v1/semantic/attestation" and method == "GET":
        return reply("200 OK", gateway.attestation(deployment))

    if path == "/v1/semantic/extract" and method == "POST":
        if _unauthorized(environ.get("HTTP_X_GATEWAY_SECRET"), environ):
            return reply("401 Unauthorized", {"outcome": "circuit_open",
                                              "detail": "unauthenticated"})
        try:
            length = int(environ.get("CONTENT_LENGTH") or 0)
            document = json.loads(environ["wsgi.input"].read(length) or b"{}")
        except (ValueError, KeyError):
            return reply("400 Bad Request",
                         {"outcome": "input_oversize", "detail": "unreadable body"})

        try:
            items = [RequestItem(entry["item_index"], entry["fields"])
                     for entry in document.get("items", [])]
        except (KeyError, TypeError):
            return reply("400 Bad Request",
                         {"outcome": "input_oversize", "detail": "malformed items"})

        try:
            result = gateway.extract(
                items, transport=transport, deployment=deployment,
                breaker=breaker,
                source_profile=document.get("source_profile", "youtube"),
                request_id=document.get("request_id"),
                timeout_s=float(document.get("timeout_s", DEFAULT_TIMEOUT_S)))
        except gateway.GatewayRefusal as refusal:
            # **A projection refusal is a 4xx.** Sent as 500 it is retried
            # forever at the head of a FIFO queue, which is the shape the device
            # half already learned once.
            status = "503 Service Unavailable" if refusal.code in _TRANSIENT \
                else "422 Unprocessable Entity"
            return reply(status, {"outcome": refusal.code, "detail": refusal.detail})
        return reply("200 OK", result)

    return reply("404 Not Found", {"outcome": "contract_mismatch",
                                   "detail": "no such route"})


#: The refusals a caller may sensibly try again later. Everything else is about
#: the request or the deployment and will fail identically next time.
_TRANSIENT = frozenset({"timeout", "rate_limited", "provider_error", "circuit_open"})
