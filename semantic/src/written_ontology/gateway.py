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
import time
from collections.abc import Callable, Sequence
from typing import Any, Protocol

from .mention_extract_v2 import (
    ExtractionInvalid,
    RequestItem,
    validate_with_schema,
)
from .semantic_contract import load as load_contract

#: The interim request contract. `mention_extract_v2`'s `source_field` enum is
#: the authority for which fields may be sent, and this reads it rather than
#: restating it — a second list is how the schema and the sender drift.
REQUEST_SCHEMA_OWED = (
    "an explicit request schema is owed: the memo asks for one bounding item "
    "count, field set, string lengths and tenant identifiers, and 1B deferred it"
)

#: Fields that must never appear in a request, whatever the caller believes.
#: The workbook says the same in `llm.input.forbidden_fields`; this is the
#: enforcement, and the overlap is deliberate — one is authored policy and the
#: other refuses at the door.
FORBIDDEN_REQUEST_KEYS = frozenset({
    "user_id", "observation_id", "email", "oauth_token", "refresh_token",
    "source_url", "raw_provenance_notes", "account_id",
})


class GatewayRefusal(RuntimeError):
    """A refusal carrying an outcome from the closed vocabulary.

    The code is what the database records, so it is taken from
    `model_invocation_items.outcome` rather than invented here.
    """

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


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
        "request_schema": REQUEST_SCHEMA_OWED,
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

    # --- step 2: the request ---------------------------------------------
    _validate_request(items, contract)

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

    # --- steps 4 and 5: the exact payload, and its budget -----------------
    payload = _serialise(items, contract)
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
        except TimeoutError:
            last = GatewayRefusal("timeout", f"attempt {attempt}")
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
})


def _contract():
    return load_contract()


def _validate_request(items: Sequence[RequestItem], contract) -> None:
    if not items:
        raise GatewayRefusal("input_oversize", "a call must carry at least one item")
    if len(items) > contract.max_items_wire:
        raise GatewayRefusal(
            "input_oversize",
            f"{len(items)} items against a wire maximum of {contract.max_items_wire}",
        )
    seen: set[int] = set()
    for item in items:
        if item.item_index in seen:
            raise GatewayRefusal("duplicate_item", f"index {item.item_index}")
        seen.add(item.item_index)
        for key in item.fields:
            if key in FORBIDDEN_REQUEST_KEYS:
                # Named without quoting the value, which is the whole point.
                raise GatewayRefusal("input_oversize", f"forbidden field {key!r}")
    if seen != set(range(len(items))):
        raise GatewayRefusal("missing_item", "item indices are not contiguous from zero")


def _serialise(items: Sequence[RequestItem], contract) -> dict[str, Any]:
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
        "input_items": [
            {"item_index": item.item_index, **item.fields} for item in items
        ],
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
