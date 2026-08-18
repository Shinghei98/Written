"""The private extraction gateway, with the model lane still off.

**Nothing here calls Qwen today**, and the property most worth holding is that
`off` is not a branch the caller takes but a state in which `extract` cannot
reach a transport at all: `health` and `attestation` answer, and every extraction
path refuses before the request is even serialised.

## Why the logic is here and the transport is not

The deployable shape — an HTTP service in front of vLLM — is Stage 3's
infrastructure. What has to be *right* is the order of the checks and what each
refusal is called, and neither needs a socket. `mention_extract_v2` already took
this shape: a pure validator whose docstring says it runs "in the order a gateway
must run them". This is the rest of that gateway, and a `ModelTransport` is
injected so a test can assert *that the model was not called* rather than trust a
mode flag.

## The ten steps, in order

The memo lists them and the order is the substance, because several of them are
only meaningful before the next one runs:

1. authenticate the worker — the transport's job, not this module's;
2. validate the request against the authorized field list;
3. compare expected identities against what is loaded;
4. serialise the exact prompt, schema and payload;
5. tokenise that exact request and check the context budget;
6. invoke the pinned revision with thinking disabled and strict structured output;
7. reject a length finish, partial JSON, an unsupported finish reason or a
   missing item;
8. JSON Schema validation;
9. request-relative validation;
10. return validated items and safe operational metadata.

Steps 8 and 9 are `mention_extract_v2.validate_with_schema`, called rather than
reimplemented.

## Every refusal has a name from the closed vocabulary

`0236` fixed fourteen operational outcomes and `0241` made an unanswered item one
of them rather than a missing row. This module raises `GatewayRefusal` carrying
exactly those codes, so what the database records is what the gateway decided —
one vocabulary, not a translation layer that can drift.

**No refusal is ever a semantic abstention.** An abstention is the model saying
the item had no durable subject; everything here is something that happened to
the call.

## What is deliberately not built

No provider-portability layer: the memo says one private vLLM deployment for the
MVP and that a second provider is a later decision. No request *schema* — 1B
deferred it, the field list below is the interim, and `REQUEST_SCHEMA_OWED`
records that rather than letting the gap look like a choice.
"""
from __future__ import annotations

import dataclasses
import json
import secrets
import time
from collections.abc import Callable, Sequence
from typing import Any, Protocol

import jsonschema

from .mention_extract_v2 import (
    ExtractionInvalid,
    RequestItem,
    validate_with_schema,
)
from .semantic_contract import load as load_contract

#: An opaque id carries nothing about whose request it is. The default is the
#: item's own position, which is meaningless by construction; a caller that needs
#: to correlate may pass its own, and the schema bounds the shape either way.
def _default_item_id(index: int) -> str:
    return f"i{index}"


class GatewayRefusal(RuntimeError):
    """A refusal carrying an outcome from the closed vocabulary.

    The code is what the database records, so it is taken from
    `model_invocation_items.outcome` rather than invented here.
    """

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


class RateLimited(RuntimeError):
    """The provider said slow down.

    Distinct from a generic provider error because it is the one failure a
    bounded retry is *for*, and because `rate_limited` is its own outcome in the
    closed vocabulary — folding it into `provider_error` would lose the
    difference between a dead endpoint and a busy one.
    """


class InferenceInFlight(RuntimeError):
    """The work was accepted and had not finished when patience ran out.

    **Distinct from `TimeoutError`, and the distinction is the whole point.** A
    `TimeoutError` may mean nothing was ever enqueued, which a second call can
    fix. This means a job exists. Answering it with another call does not retry
    the work, it duplicates it — on an endpoint held at one instance the copy
    queues behind the original, and the original's answer then lands in a bucket
    with nobody left to read it or delete it.

    So it is terminal for the attempt. The ticket travels on the exception so a
    caller that wants the answer can collect the same job later rather than
    starting a second one.
    """

    def __init__(self, ticket: Any) -> None:
        super().__init__("the endpoint accepted the work and has not answered")
        self.ticket = ticket


class RetentionFailure(RuntimeError):
    """The answer was read and its copy could not be deleted.

    **Distinct from every other failure because the model succeeded.** The
    mentions are valid and they are withheld anyway: committing semantics
    derived from text we cannot show we stopped holding is the trade this
    refuses. `0242` is where the outcome lives, and the bucket's one-day
    lifecycle rule is a backstop for a process that died rather than a licence
    to proceed past this.
    """


class ModelTransport(Protocol):
    """Whatever actually reaches the serving engine.

    Injected so a test can assert the model was **not** called, which is the one
    thing a mode flag cannot demonstrate about itself.
    """

    def complete(self, payload: dict[str, Any], timeout_s: float) -> dict[str, Any]:
        ...


@dataclasses.dataclass(frozen=True)
class Deployment:
    """What is actually loaded, as opposed to what the contract expects.

    Step 3 compares the two. A gateway that reported the contract's own values
    back would be attesting to itself.
    """

    model_id: str
    model_revision: str
    tokenizer_sha256: str
    gateway_image_digest: str
    serving_image_digest: str
    prompt_version: str
    grammar_version: str
    output_schema_sha256: str
    contract_sha256: str
    environment: str


class CircuitBreaker:
    """Opens on sustained failure and stays open for a cooling period.

    The workbook's `llm.circuit_breaker` says *open on sustained error or
    latency; continue deterministic lane* — the second half is a property of the
    caller, not of this class, and is why opening raises `circuit_open` rather
    than blocking.
    """

    def __init__(self, threshold: int = 5, cool_off_s: float = 60.0,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self._threshold = threshold
        self._cool_off = cool_off_s
        self._clock = clock
        self._failures = 0
        self._opened_at: float | None = None

    @property
    def is_open(self) -> bool:
        if self._opened_at is None:
            return False
        if self._clock() - self._opened_at >= self._cool_off:
            # Half-open: one call is allowed through to find out.
            self._opened_at = None
            self._failures = 0
            return False
        return True

    def record_success(self) -> None:
        self._failures = 0
        self._opened_at = None

    def record_failure(self) -> None:
        self._failures += 1
        if self._failures >= self._threshold:
            self._opened_at = self._clock()

    def trip(self) -> None:
        """Open immediately, for a mismatch that a retry cannot fix."""
        self._failures = self._threshold
        self._opened_at = self._clock()


def health() -> dict[str, Any]:
    """Available in every mode, including `off`.

    A health check that answered only when the lane was on could not tell a
    disabled gateway from a dead one, which is the question it exists for.
    """
    return {"status": "ok", "extraction_enabled": _contract().model_may_be_called}


def attestation(deployment: Deployment | None = None) -> dict[str, Any]:
    """What is loaded, beside what the contract expects.

    Also available in every mode: attesting a deployment is how `off → evaluation`
    is decided, so it has to work before the transition rather than after it.
    """
    contract = _contract()
    expected = contract.attestation()
    report: dict[str, Any] = {
        "expected": expected,
        "model_lane_mode": contract.model_lane_mode,
        "extraction_enabled": contract.model_may_be_called,
        "may_write_user_candidates": contract.may_write_user_candidates,
        "request_schema": contract.request_schema["$id"],
    }
    if deployment is None:
        report["loaded"] = None
        report["matches"] = None
        return report

    loaded = dataclasses.asdict(deployment)
    report["loaded"] = loaded
    report["matches"] = {
        "model_id": loaded["model_id"] == expected["model_id"],
        "model_revision": loaded["model_revision"] == expected["model_revision"],
        "prompt_version": loaded["prompt_version"] == expected["prompt_version"],
        "grammar_version": loaded["grammar_version"] == expected["grammar_version"],
        "output_schema_sha256":
            loaded["output_schema_sha256"] == expected["schema_sha256"],
        "contract_sha256": loaded["contract_sha256"] == expected["compiled_contract_sha256"],
    }
    report["attested"] = all(report["matches"].values())
    return report


def extract(
    items: Sequence[RequestItem],
    *,
    transport: ModelTransport | None = None,
    deployment: Deployment | None = None,
    breaker: CircuitBreaker | None = None,
    tokenize: Callable[[str], int] | None = None,
    max_attempts: int = 2,
    timeout_s: float = 30.0,
    source_profile: str = "youtube",
    request_id: str | None = None,
    item_ids: dict[int, str] | None = None,
) -> dict[str, Any]:
    """One extraction call, or a named refusal.

    Returns validated items and safe operational metadata — counts, codes and
    token figures. **Never the response body**, and never a provider error
    message: §20.1 and the reason `model_invocation_items` has no text column.
    """
    contract = _contract()

    # --- step 0: the lane -------------------------------------------------
    #
    # **Before anything is serialised and before a transport is touched.** The
    # property worth having is not that `off` returns an error but that the
    # model cannot be reached in it, which is why this precedes request
    # validation: a malformed request in `off` must still not produce a call.
    if not contract.model_may_be_called:
        raise GatewayRefusal(
            "circuit_open",
            f"the model lane is {contract.model_lane_mode!r}; extraction is not permitted",
        )

    if breaker is not None and breaker.is_open:
        raise GatewayRefusal("circuit_open", "the breaker is open")

    # --- steps 2 and 4: the exact document, then its schema ---------------
    request = build_request(items, contract, source_profile=source_profile,
                            request_id=request_id, item_ids=item_ids)
    _validate_request(request, items, contract)

    # --- step 3: identities ----------------------------------------------
    if deployment is None:
        raise GatewayRefusal(
            "contract_mismatch", "nothing is attested as loaded")
    report = attestation(deployment)
    if not report["attested"]:
        mismatched = sorted(k for k, ok in report["matches"].items() if not ok)
        if breaker is not None:
            # A mismatch is not transient and a retry makes it worse: it would
            # keep a wrong model answering.
            breaker.trip()
        raise GatewayRefusal("contract_mismatch", ",".join(mismatched))

    if transport is None:
        raise GatewayRefusal("provider_error", "no transport is configured")

    # --- step 5: the budget ----------------------------------------------
    payload = _serialise(request, contract)
    if tokenize is not None:
        budget = contract.max_output_tokens
        serialised = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        if tokenize(serialised) + budget > contract.max_output_tokens * 8:
            # A deliberately generous context bound: the real one comes from the
            # deployed model's window, which only the deployment knows.
            raise GatewayRefusal("input_oversize", "the request exceeds the context budget")

    # --- step 6: invoke, with bounded retry ------------------------------
    last: GatewayRefusal | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            started = time.monotonic()
            response = transport.complete(payload, timeout_s)
            latency_ms = int((time.monotonic() - started) * 1000)
        except InferenceInFlight:
            # **Not retried.** The work exists; a second call would be a second
            # job, not another go at the first. The outcome is still `timeout`
            # — that is what the closed vocabulary calls "we did not get an
            # answer" — but it leaves the loop here rather than round it.
            if breaker is not None:
                breaker.record_failure()
            raise GatewayRefusal("timeout", "accepted, unanswered") from None
        except TimeoutError:
            # Nothing was accepted, so nothing is duplicated by asking again.
            last = GatewayRefusal("timeout", f"attempt {attempt}")
        except RateLimited:
            last = GatewayRefusal("rate_limited", f"attempt {attempt}")
        except RetentionFailure as failure:
            # Not retried and not softened. A second call would leave a second
            # object beside the first.
            if breaker is not None:
                breaker.record_failure()
            raise GatewayRefusal("retention_failed", str(failure)) from None
        except Exception as failure:  # noqa: BLE001 - classified, never quoted
            last = GatewayRefusal("provider_error", type(failure).__name__)
        else:
            try:
                result = _accept(response, items, contract)
            except GatewayRefusal as refusal:
                # **A structural refusal is not retried under the same prompt.**
                # The memo is explicit: a compact fallback is a distinct schema
                # and prompt profile, and a hidden "be shorter" retry would make
                # the recorded prompt version untrue.
                if refusal.code in _NOT_RETRYABLE:
                    if breaker is not None:
                        breaker.record_failure()
                    raise
                last = refusal
            else:
                if breaker is not None:
                    breaker.record_success()
                result["latency_ms"] = latency_ms
                result["attempts"] = attempt
                return result
        if breaker is not None:
            breaker.record_failure()

    assert last is not None
    raise last


#: Refusals a second identical call cannot fix. Retrying them wastes a call and,
#: for `output_overflow`, would keep asking a model to be shorter without saying
#: so in the prompt version.
_NOT_RETRYABLE = frozenset({
    "output_overflow", "schema_invalid", "offset_invalid", "missing_item",
    "duplicate_item", "input_oversize", "contract_mismatch",
    "retention_failed",
})


def _contract():
    return load_contract()


def build_request(items: Sequence[RequestItem], contract, *,
                  source_profile: str = "youtube",
                  request_id: str | None = None,
                  item_ids: dict[int, str] | None = None) -> dict[str, Any]:
    """The extraction request document, as `mention_extract_request_v1` defines it.

    Separate from the provider envelope: one is what the model is asked, the
    other is how it is asked. `llm.input.fields` describes this one.
    """
    ids = item_ids or {}
    return {
        "schema_version": contract.request_schema["properties"]["schema_version"]["const"],
        "prompt_version": contract.attestation()["prompt_version"],
        "grammar_version": contract.attestation()["grammar_version"],
        "source_profile": source_profile,
        "request_id": request_id or secrets.token_urlsafe(12).replace("=", ""),
        "items": [
            {
                "item_index": item.item_index,
                "item_id": ids.get(item.item_index, _default_item_id(item.item_index)),
                "fields": dict(item.fields),
            }
            for item in items
        ],
    }


def _validate_request(request: dict[str, Any], items: Sequence[RequestItem],
                      contract) -> None:
    """**The document that will actually be sent, against the schema.**

    The memo lists request validation before serialisation. Validating the
    serialised document instead is strictly stronger — it is the thing that
    leaves — and it is why `additionalProperties: false` does the work that a
    forbidden-key list used to: a user id, an observation id or an email address
    is refused because it was never permitted, not because somebody remembered
    to name it. The failure mode of a deny-list is silence.
    """
    if not items:
        raise GatewayRefusal("input_oversize", "a call must carry at least one item")

    errors = sorted(
        jsonschema.Draft202012Validator(contract.request_schema).iter_errors(request),
        key=lambda e: list(e.absolute_path),
    )
    if errors:
        first = errors[0]
        where = "/".join(str(p) for p in first.absolute_path) or "<root>"
        # The path and the rule, never the value: a request is somebody's title.
        raise GatewayRefusal(
            "input_oversize", f"{where} violates {first.validator}")

    seen = [item["item_index"] for item in request["items"]]
    if len(set(seen)) != len(seen):
        raise GatewayRefusal("duplicate_item", "an item index appears twice")
    if set(seen) != set(range(len(seen))):
        raise GatewayRefusal("missing_item", "item indices are not contiguous from zero")


def _serialise(request: dict[str, Any], contract) -> dict[str, Any]:
    """The exact payload, built once and hashed by the caller if it wants.

    `enable_thinking` is false and the response format is strict: both are
    workbook facts (`llm.qwen.enable_thinking`, `llm.response_format`) and both
    are properties of the request rather than of the deployment, so they belong
    here where they can be seen.
    """
    return {
        "model": contract.attestation()["model_id"],
        "model_revision": contract.attestation()["model_revision"],
        "temperature": 0,
        "max_output_tokens": contract.max_output_tokens,
        "enable_thinking": False,
        "response_format": {
            "type": "json_schema",
            "name": contract.output_schema_name,
            "strict": True,
        },
        "metadata": {
            "prompt_version": contract.attestation()["prompt_version"],
            "grammar_version": contract.attestation()["grammar_version"],
        },
        "input": request,
    }


def _accept(response: dict[str, Any], items: Sequence[RequestItem],
            contract) -> dict[str, Any]:
    """Steps 7 through 10."""
    finish = response.get("finish_reason")
    if finish == "length":
        raise GatewayRefusal("output_overflow", "the response was truncated")
    if finish not in {"stop", None}:
        raise GatewayRefusal("provider_error", f"finish_reason {finish!r}")

    body = response.get("body")
    if not isinstance(body, dict):
        raise GatewayRefusal("schema_invalid", "the response carried no object")

    try:
        validate_with_schema(body, list(items), contract.output_schema)
    except ExtractionInvalid as refusal:
        raise GatewayRefusal(_OUTCOME_FOR.get(refusal.code, "schema_invalid"),
                             refusal.code) from None

    returned = {item["item_index"] for item in body["items"]}
    expected = {item.item_index for item in items}
    if returned != expected:
        missing = expected - returned
        raise GatewayRefusal(
            "missing_item" if missing else "duplicate_item",
            f"{len(missing or (returned - expected))} item(s)",
        )

    return {
        "items": body["items"],
        "mention_count": sum(len(i.get("mentions", [])) for i in body["items"]),
        "output_tokens": response.get("output_tokens"),
        "outcome": "succeeded",
    }


#: Which validator refusal is which operational outcome. A mapping rather than a
#: guess, so a new structural code has to be placed deliberately instead of
#: falling into `schema_invalid` and looking like malformed JSON.
_OUTCOME_FOR = {
    "surface_offset_mismatch": "offset_invalid",
    "surface_normalization_mismatch": "offset_invalid",
    "offset_out_of_bounds": "offset_invalid",
    "end_not_after_start": "offset_invalid",
    "duplicate_span_and_role": "duplicate_item",
    "item_indices_do_not_match_request": "missing_item",
}
