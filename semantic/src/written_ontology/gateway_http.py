"""The gateway's transport and its request surface.

Kept apart from `gateway` deliberately: that module holds the order of the checks
and the name of every refusal, and neither needs a socket. This one holds the
socket and nothing else, so a change to the wire cannot quietly change a rule.

## Three routes, and two of them answer in every mode

    health
    v1/semantic/attestation
    v1/semantic/extract

**The gateway is a Lambda container invoked directly by the worker over IAM**,
not a service behind a URL. So a route is a field in an event rather than a path
in a request line, and there is no public surface to authenticate — IAM is the
authentication, and `lambda:InvokeFunction` is granted to exactly one role.

`dispatch` is the one definition. The Lambda handler and the local WSGI harness
are both adapters over it, so a rule cannot hold on one surface and not the
other; the harness exists to answer the routes over a socket while proving `off`
and has no production role.

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

## Authentication is IAM, and the shared secret is the harness's

There is no function URL and no API Gateway, so the only caller is a principal
AWS has already authenticated. The local harness still checks
`x-gateway-secret`, because a socket on a laptop has no IAM in front of it, and
an unset secret refuses rather than opens.
"""
from __future__ import annotations

import hmac
import json
import os
from typing import Any

from . import gateway
from .mention_extract_v2 import RequestItem

#: How long the model gets. `llm.gateway.timeout_ms` in the workbook.
#: How long one call waits before handing back a ticket.
#:
#: **Not how long the work may take.** Thirty seconds was the whole budget when
#: there was nothing to hand back, so a slow answer was a lost one; starting a
#: scaled-to-zero g6e and loading 19 GB is minutes, and every first request of
#: the day would have been abandoned. With continuation the question is only how
#: much of one Lambda invocation to spend waiting before returning a request id,
#: and the function's own timeout is 300 — so this leaves room to answer rather
#: than being killed mid-poll with the ticket unreported.
DEFAULT_TIMEOUT_S = 120.0


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


def dispatch(request: dict[str, Any], *, deployment=None, transport=None,
             breaker=None) -> tuple[int, dict[str, Any]]:
    """One route, one answer. The only definition of what the gateway does.

    Returns a status and a body rather than writing either, so the Lambda
    handler and the local harness cannot disagree about a refusal.
    """
    route = (request.get("route") or "").strip("/")

    if route == "health":
        return 200, gateway.health()

    if route == "v1/semantic/attestation":
        return 200, gateway.attestation(deployment)

    if route == "v1/semantic/extract":
        try:
            items = [RequestItem(entry["item_index"], entry["fields"])
                     for entry in request.get("items", [])]
        except (KeyError, TypeError):
            return 400, {"outcome": "input_oversize", "detail": "malformed items"}
        try:
            result = gateway.extract(
                items, transport=transport, deployment=deployment,
                breaker=breaker,
                source_profile=request.get("source_profile", "youtube"),
                request_id=request.get("request_id"),
                timeout_s=float(request.get("timeout_s", DEFAULT_TIMEOUT_S)))
        except gateway.GatewayRefusal as refusal:
            # **A projection refusal is a 4xx.** Sent as 500 it is retried
            # forever at the head of a FIFO queue, which the device half already
            # learned once.
            status = 503 if refusal.code in _TRANSIENT else 422
            body = {"outcome": refusal.code, "detail": refusal.detail}
            resume = getattr(refusal, "resume_request_id", None)
            if resume:
                # **The difference between "ask again" and "come back for it".**
                # A caller told only `timeout` can do nothing but resubmit, and
                # the work is already running.
                body["resume"] = {"route": "v1/semantic/collect",
                                  "request_id": resume}
            return status, body
        return 200, result

    if route == "v1/semantic/collect":
        # Collecting is not extracting: it submits nothing, so it does not go
        # through the lane gate a submission does. It is refused for the one
        # reason that matters — there is nothing to collect — rather than
        # answering a caller that holds a real ticket with a policy error.
        request_id = request.get("request_id")
        if not request_id:
            return 400, {"outcome": "contract_mismatch",
                         "detail": "request_id is required"}
        if transport is None or not hasattr(transport, "resume"):
            return 503, {"outcome": "provider_error",
                         "detail": "this deployment cannot continue a ticket"}
        try:
            answer = transport.resume(
                request_id, float(request.get("timeout_s", DEFAULT_TIMEOUT_S)))
        except gateway.InferenceInFlight:
            return 503, {"outcome": "timeout", "detail": "still running",
                         "resume": {"route": "v1/semantic/collect",
                                    "request_id": request_id}}
        except gateway.GatewayRefusal as refusal:
            status = 503 if refusal.code in _TRANSIENT else 422
            return status, {"outcome": refusal.code, "detail": refusal.detail}
        except gateway.RetentionFailure as failure:
            return 422, {"outcome": "retention_failed", "detail": str(failure)}
        except Exception as failure:  # noqa: BLE001 - classified, never quoted
            return 503, {"outcome": "provider_error",
                         "detail": type(failure).__name__}
        # **Validated exactly as a fresh answer is.** A late answer is not a
        # trusted one, and routing it round `_accept` would be a second door
        # into user semantics with no schema check behind it.
        try:
            return 200, gateway.accept_response(answer, request.get("items", []))
        except gateway.GatewayRefusal as refusal:
            return 422, {"outcome": refusal.code, "detail": refusal.detail}

    return 404, {"outcome": "contract_mismatch", "detail": "no such route"}


def application(environ, start_response, *, deployment=None, transport=None,
                breaker=None):
    """A local harness over `dispatch`, and nothing production depends on it.

    The gateway ships as a Lambda container with no URL. This exists so the
    routes can be answered over a real socket while the lane is off, which is
    the one thing a flag cannot demonstrate about itself.
    """
    path = environ.get("PATH_INFO", "")
    method = environ.get("REQUEST_METHOD", "GET")

    def reply(code: int, body: dict[str, Any]):
        payload = json.dumps(body).encode()
        start_response(f"{code} {_REASON.get(code, 'OK')}",
                       [("content-type", "application/json"),
                        ("content-length", str(len(payload)))])
        return [payload]

    request: dict[str, Any] = {"route": path}
    if method == "POST":
        if _unauthorized(environ.get("HTTP_X_GATEWAY_SECRET"), environ):
            return reply(401, {"outcome": "circuit_open",
                               "detail": "unauthenticated"})
        try:
            length = int(environ.get("CONTENT_LENGTH") or 0)
            request |= json.loads(environ["wsgi.input"].read(length) or b"{}")
        except (ValueError, KeyError):
            return reply(400, {"outcome": "input_oversize",
                               "detail": "unreadable body"})
        request["route"] = path

    code, body = dispatch(request, deployment=deployment, transport=transport,
                          breaker=breaker)
    return reply(code, body)


_REASON = {200: "OK", 400: "Bad Request", 401: "Unauthorized",
           404: "Not Found", 422: "Unprocessable Entity",
           503: "Service Unavailable"}


#: The refusals a caller may sensibly try again later. Everything else is about
#: the request or the deployment and will fail identically next time.
_TRANSIENT = frozenset({"timeout", "rate_limited", "provider_error", "circuit_open"})
