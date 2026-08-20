"""The gateway, with the model lane off.

The property worth proving is not that `off` returns an error — a branch can
always be written to do that — but that **the transport is never reached in it**.
Every test here injects a counting transport and asserts the count, because a
mode flag cannot demonstrate anything about itself.
"""
from __future__ import annotations

import json
import pathlib

import pytest

from written_ontology import gateway
from written_ontology.mention_extract_v2 import RequestItem
from written_ontology.semantic_contract import SemanticContract, contract_path

REQUEST = [RequestItem(0, {"title": "Midnight"})]


class CountingTransport:
    """Records every call, and answers with whatever it was given."""

    def __init__(self, response=None, raises=None):
        self.calls = 0
        self._response = response
        self._raises = raises

    def complete(self, payload, timeout_s):
        self.calls += 1
        if self._raises is not None:
            raise self._raises
        return self._response


def contract_in_lane(tmp_path: pathlib.Path, lane: str) -> SemanticContract:
    """A real contract, read by the real reader, in the lane asked for.

    A stub would not notice the reader changing, and the reader is half of what
    these tests are about.
    """
    data = json.loads(contract_path().read_text())
    data["runtime_requirements"]["qwen_overlay"] = lane
    # **A fully attested pair, because the attested path is what most of these
    # exercise.** In the tree these two are placeholders until a GPU measures
    # one and a build produces the other, and `attestation` correctly withholds
    # attestation while they are — which is asserted directly in
    # `test_a_placeholder_expectation_withholds_attestation` rather than left
    # as the ambient state of every other test.
    data["output_contract"]["tokenizer_manifest_sha256"] = "tok" * 21 + "1"
    data["versions"]["serving_image_digest"] = "sha256:serving"
    copy = tmp_path / "compiled_semantic_contract_v1.json"
    copy.write_text(json.dumps(data))
    return SemanticContract(copy)


def matching_deployment(contract) -> gateway.Deployment:
    expected = contract.attestation()
    return gateway.Deployment(
        model_id=expected["model_id"],
        model_revision=expected["model_revision"],
        tokenizer_sha256=expected["tokenizer_manifest_sha256"],
        gateway_revision=expected["gateway_revision"],
        gateway_image_digest="sha256:g",
        serving_image_digest=expected["serving_image_digest"],
        prompt_version=expected["prompt_version"],
        grammar_version=expected["grammar_version"],
        output_schema_sha256=expected["schema_sha256"],
        contract_sha256=expected["compiled_contract_sha256"],
        environment="test",
    )


#: The runtime the serving container measures and sends with every answer.
#: **Part of a valid response, not an extra.** A body without it is one whose
#: author cannot be checked, and the gateway refuses it — so a fixture without
#: it is not a simpler valid response, it is an invalid one.
def matching_runtime(contract=None):
    # `gateway._contract()` rather than a fresh load: the tests patch it, and a
    # fixture that read the real contract while the test used another would
    # drift on exactly the field being asserted.
    expected = (contract or gateway._contract()).attestation()
    return {"model_id": expected["model_id"],
            "model_revision": expected["model_revision"],
            # **The canonical runtime manifest digest**, which is what the
            # contract pins — not `tokenizer_json_sha256`, which identifies a
            # file and says nothing about the chat template or the library
            # versions the budgets were measured under.
            "tokenizer_runtime_manifest_sha256":
                expected["tokenizer_manifest_sha256"],
            "serving_image_digest": expected["serving_image_digest"],
            "vllm": "0.11.0", "torch": "2.8.0"}


def valid_response(items=REQUEST, contract=None):
    return {
        "finish_reason": "stop",
        "output_tokens": 120,
        "runtime": matching_runtime(contract),
        "body": {
            "schema_version": "mention_extract_v2",
            "items": [{
                "item_index": item.item_index,
                "status": "extracted",
                "abstain_reason": None,
                "mentions": [{
                    "surface": "Midnight",
                    "source_field": "title",
                    "source_field_index": None,
                    "start": 0,
                    "end": 8,
                    "canonical_label_hypothesis": "Midnight",
                    "family_hypothesis": "work",
                    "mention_role": "work_or_franchise",
                    "conversation_worthy": True,
                }],
            } for item in items],
        },
    }


# ---------------------------------------------------------------------------
# Off
# ---------------------------------------------------------------------------

def test_health_answers_when_the_lane_is_off(monkeypatch, tmp_path):
    """A health check that answered only when the lane was on could not tell a
    disabled gateway from a dead one, which is the question it exists for."""
    _lane_off(monkeypatch, tmp_path)
    report = gateway.health()
    assert report["status"] == "ok"
    assert report["extraction_enabled"] is False


def _lane_off(monkeypatch, tmp_path):
    """The artifact moved to `evaluation` on 2026-08-19; `off` is synthesized.

    These tests are about what `off` *refuses*, which must keep being tested
    after the shipped mode has moved — a mode ladder climbs back down too.
    """
    contract = contract_in_lane(tmp_path, "off")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)


def test_attestation_answers_when_the_lane_is_off(monkeypatch, tmp_path):
    """Attesting a deployment is how off-to-evaluation is decided, so it has to
    work before the transition rather than after it."""
    _lane_off(monkeypatch, tmp_path)
    report = gateway.attestation()
    assert report["model_lane_mode"] == "off"
    assert report["extraction_enabled"] is False
    assert report["may_write_user_candidates"] is False
    assert report["expected"]["compiled_contract_sha256"]
    assert report["loaded"] is None


def test_off_reaches_no_transport(monkeypatch, tmp_path):
    """**The one that matters.** Not that `off` refuses, but that nothing is
    called in it."""
    _lane_off(monkeypatch, tmp_path)
    transport = CountingTransport(response=valid_response())
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport)
    assert refusal.value.code == "circuit_open"
    assert transport.calls == 0


def test_off_reaches_no_transport_even_for_a_malformed_request(monkeypatch, tmp_path):
    """The lane check precedes request validation deliberately: a bad request in
    `off` must still not produce a call, and an ordering that validated first
    would make the refusal depend on the caller getting the request right."""
    _lane_off(monkeypatch, tmp_path)
    transport = CountingTransport(response=valid_response())
    with pytest.raises(gateway.GatewayRefusal):
        gateway.extract([], transport=transport)
    assert transport.calls == 0


def test_off_reaches_no_transport_with_a_mismatched_deployment(monkeypatch, tmp_path):
    _lane_off(monkeypatch, tmp_path)
    transport = CountingTransport(response=valid_response())
    wrong = gateway.Deployment(
        model_id="somebody-elses-model", model_revision="x", tokenizer_sha256="t",
        gateway_revision="r", gateway_image_digest="g", serving_image_digest="s",
        prompt_version="p",
        grammar_version="g", output_schema_sha256="s", contract_sha256="c",
        environment="test")
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport, deployment=wrong)
    assert refusal.value.code == "circuit_open"
    assert transport.calls == 0


# ---------------------------------------------------------------------------
# With the lane open — every refusal named, and the successful path
# ---------------------------------------------------------------------------

@pytest.fixture
def shadow(tmp_path, monkeypatch):
    contract = contract_in_lane(tmp_path, "shadow")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)
    return contract


def test_a_matching_deployment_extracts_and_returns_no_body(shadow):
    transport = CountingTransport(response=valid_response())
    result = gateway.extract(REQUEST, transport=transport,
                             deployment=matching_deployment(shadow))
    assert transport.calls == 1
    assert result["outcome"] == "succeeded"
    assert result["mention_count"] == 1
    assert result["output_tokens"] == 120
    # Safe operational metadata only: counts, codes and figures. §20.1 and the
    # reason `model_invocation_items` has no text column.
    assert "body" not in result and "response" not in result


def test_a_mismatched_deployment_is_contract_mismatch_and_trips_the_breaker(shadow):
    transport = CountingTransport(response=valid_response())
    breaker = gateway.CircuitBreaker()
    wrong = matching_deployment(shadow)
    wrong = gateway.Deployment(**{**wrong.__dict__, "model_revision": "not-the-pin"})
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport, deployment=wrong,
                        breaker=breaker)
    assert refusal.value.code == "contract_mismatch"
    assert transport.calls == 0
    # A mismatch is not transient: retrying keeps a wrong model answering.
    assert breaker.is_open


def test_a_truncated_response_is_overflow_and_is_not_retried(shadow):
    truncated = valid_response()
    truncated["finish_reason"] = "length"
    transport = CountingTransport(response=truncated)
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport,
                        deployment=matching_deployment(shadow), max_attempts=3)
    assert refusal.value.code == "output_overflow"
    # **Never a hidden "be shorter" retry.** A compact fallback is a distinct
    # prompt and schema profile and must appear in provenance.
    assert transport.calls == 1


def test_a_timeout_is_retried_and_then_named(shadow):
    transport = CountingTransport(raises=TimeoutError())
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport,
                        deployment=matching_deployment(shadow), max_attempts=3)
    assert refusal.value.code == "timeout"
    assert transport.calls == 3


def test_an_item_the_model_did_not_answer_is_missing_item(shadow):
    two = [RequestItem(0, {"title": "Midnight"}), RequestItem(1, {"title": "Dawn"})]
    partial = valid_response(two)
    partial["body"]["items"] = partial["body"]["items"][:1]
    transport = CountingTransport(response=partial)
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(two, transport=transport,
                        deployment=matching_deployment(shadow))
    assert refusal.value.code == "missing_item"


def test_a_bad_offset_is_offset_invalid_rather_than_schema_invalid(shadow):
    """The mapping exists so a structural code is placed deliberately instead of
    falling into `schema_invalid` and reading like malformed JSON.

    The surface here is absent from the source, so the offset repair cannot
    touch it — a surface the source does not contain has no honest span."""
    wrong = valid_response()
    wrong["body"]["items"][0]["mentions"][0]["surface"] = "Xidnight"
    transport = CountingTransport(response=wrong)
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport,
                        deployment=matching_deployment(shadow))
    assert refusal.value.code == "offset_invalid"


def test_wrong_arithmetic_on_a_unique_surface_is_repaired_not_refused(shadow):
    """The model named the right entity and miscounted its code points. Where
    the surface occurs exactly once in the cited field, the span is not in
    doubt: the offsets are recomputed and the repair is counted rather than
    swallowed."""
    wrong = valid_response()
    mention = wrong["body"]["items"][0]["mentions"][0]
    mention["start"], mention["end"] = 1, 6  # arithmetic off; surface unique
    transport = CountingTransport(response=wrong)
    answer = gateway.extract(REQUEST, transport=transport,
                             deployment=matching_deployment(shadow))
    assert answer["offsets_repaired"] == 1
    repaired = answer["items"][0]["mentions"][0]
    assert (repaired["start"], repaired["end"]) == (0, 8)


def test_no_refusal_is_ever_a_semantic_abstention(shadow):
    """An abstention is the model saying the item had no durable subject.
    Everything this module raises is something that happened to the call."""
    cases = []
    truncated = valid_response(); truncated["finish_reason"] = "length"
    cases.append(truncated)
    empty = valid_response(); empty["body"] = None
    cases.append(empty)
    for response in cases:
        with pytest.raises(gateway.GatewayRefusal) as refusal:
            gateway.extract(REQUEST, transport=CountingTransport(response=response),
                            deployment=matching_deployment(shadow))
        assert refusal.value.code != "semantic_abstention"


def test_the_breaker_opens_and_then_refuses_without_calling(shadow):
    transport = CountingTransport(raises=RuntimeError("upstream"))
    breaker = gateway.CircuitBreaker(threshold=2)
    for _ in range(2):
        with pytest.raises(gateway.GatewayRefusal):
            gateway.extract(REQUEST, transport=transport,
                            deployment=matching_deployment(shadow),
                            breaker=breaker, max_attempts=1)
    assert breaker.is_open
    before = transport.calls
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=transport,
                        deployment=matching_deployment(shadow), breaker=breaker)
    assert refusal.value.code == "circuit_open"
    assert transport.calls == before


def test_a_request_over_the_wire_maximum_is_refused_before_the_call(shadow):
    too_many = [RequestItem(i, {"title": f"t{i}"})
                for i in range(shadow.max_items_wire + 1)]
    transport = CountingTransport(response=valid_response())
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(too_many, transport=transport,
                        deployment=matching_deployment(shadow))
    assert refusal.value.code == "input_oversize"
    assert transport.calls == 0


# ---------------------------------------------------------------------------
# The request schema, which is an allowlist rather than a deny-list
# ---------------------------------------------------------------------------

def test_a_tenant_identifier_is_refused_because_it_was_never_permitted(shadow):
    """`additionalProperties: false` does the work a forbidden-key list used to.

    The list had to be remembered; this refuses anything nobody permitted, which
    is the difference the repository states as *the failure mode of a deny-list
    is silence*.
    """
    leaky = [RequestItem(0, {"title": "Midnight", "user_id": "0000-secret"})]
    transport = CountingTransport(response=valid_response())
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(leaky, transport=transport,
                        deployment=matching_deployment(shadow))
    assert refusal.value.code == "input_oversize"
    # The path and the rule, never the value: a request is somebody's title.
    assert "secret" not in str(refusal.value)
    assert transport.calls == 0


def test_an_over_long_title_is_refused_at_the_bound_the_workbook_authored(shadow):
    bound = shadow.request_schema["$defs"]["fields"]["properties"]["title"]["maxLength"]
    transport = CountingTransport(response=valid_response())
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract([RequestItem(0, {"title": "x" * (bound + 1)})],
                        transport=transport, deployment=matching_deployment(shadow))
    assert refusal.value.code == "input_oversize"
    assert transport.calls == 0


def test_the_built_request_validates_against_its_own_schema(shadow):
    import jsonschema
    request = gateway.build_request(REQUEST, shadow)
    jsonschema.validate(request, shadow.request_schema)
    assert request["items"][0]["item_id"] == "i0"


def test_an_item_id_carries_nothing_by_default(shadow):
    """It correlates a response with a request and must say nothing about whose."""
    request = gateway.build_request(
        [RequestItem(0, {"title": "a"}), RequestItem(1, {"title": "b"})], shadow)
    assert [i["item_id"] for i in request["items"]] == ["i0", "i1"]


# ---------------------------------------------------------------------------
# The HTTP surface
# ---------------------------------------------------------------------------

def call(path, method="GET", body=None, secret=None, **kwargs):
    import io
    from written_ontology import gateway_http
    raw = json.dumps(body or {}).encode()
    environ = {
        "PATH_INFO": path, "REQUEST_METHOD": method,
        "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw),
    }
    if secret is not None:
        environ["HTTP_X_GATEWAY_SECRET"] = secret
    captured = {}

    def start_response(status, headers):
        captured["status"] = status

    payload = gateway_http.application(environ, start_response, **kwargs)
    return captured["status"], json.loads(b"".join(payload))


def test_health_and_attestation_report_the_artifact_mode():
    """`evaluation` on 2026-08-19, `shadow` on 2026-08-20 (owner decision:
    the evaluation lane had said all it could — one turn per user per release —
    and shadow is the first mode where output may attach to a person, still
    unpublished). These follow the artifact."""
    status, body = call("/health")
    assert status.startswith("200") and body["extraction_enabled"] is True
    status, body = call("/v1/semantic/attestation")
    assert status.startswith("200") and body["model_lane_mode"] == "shadow"


def test_extract_with_the_lane_on_but_nothing_attested_reaches_no_transport(monkeypatch):
    monkeypatch.setenv("WRITTEN_GATEWAY_SECRET", "s3cret")
    transport = CountingTransport(response=valid_response())
    status, body = call("/v1/semantic/extract", "POST",
                        {"items": [{"item_index": 0, "fields": {"title": "Midnight"}}]},
                        secret="s3cret", transport=transport)
    # **422 `contract_mismatch`, and it is deliberately not transient.** With the
    # lane on and nothing attested as loaded, the refusal must not be retried —
    # a retry would keep asking an unattested deployment — and above all the
    # transport must never be touched.
    assert status.startswith("422")
    assert body["outcome"] == "contract_mismatch"
    assert transport.calls == 0


def test_an_unset_secret_refuses_rather_than_opens(monkeypatch):
    """A gateway that served anyone because nobody set a variable is the failure
    this check exists to prevent."""
    monkeypatch.delenv("WRITTEN_GATEWAY_SECRET", raising=False)
    status, body = call("/v1/semantic/extract", "POST", {"items": []}, secret="")
    assert status.startswith("401")


def test_a_wrong_secret_is_refused(monkeypatch):
    monkeypatch.setenv("WRITTEN_GATEWAY_SECRET", "s3cret")
    status, _ = call("/v1/semantic/extract", "POST", {"items": []}, secret="nope")
    assert status.startswith("401")


def test_an_unknown_route_is_not_found():
    status, body = call("/v1/semantic/anything")
    assert status.startswith("404")


def test_a_request_refusal_is_a_4xx_and_a_provider_refusal_a_5xx(shadow, monkeypatch):
    """A projection refusal sent as a 500 is retried forever at the head of a
    FIFO queue, which the device half already learned once."""
    monkeypatch.setenv("WRITTEN_GATEWAY_SECRET", "s3cret")
    deployment = matching_deployment(shadow)

    status, body = call(
        "/v1/semantic/extract", "POST",
        {"items": [{"item_index": 0, "fields": {"title": "x" * 5000}}]},
        secret="s3cret", transport=CountingTransport(response=valid_response()),
        deployment=deployment)
    assert status.startswith("422") and body["outcome"] == "input_oversize"

    status, body = call(
        "/v1/semantic/extract", "POST",
        {"items": [{"item_index": 0, "fields": {"title": "Midnight"}}]},
        secret="s3cret", transport=CountingTransport(raises=TimeoutError()),
        deployment=deployment)
    assert status.startswith("503") and body["outcome"] == "timeout"


# ---------------------------------------------------------------------------
# Attestation covers every loaded field, or it is not attestation
# ---------------------------------------------------------------------------

def test_every_loaded_field_is_compared_unless_it_is_named_exempt(tmp_path,
                                                                    monkeypatch):
    """A hand-written list of comparisons is a deny-list of what it forgot.

    `tokenizer_sha256` and both image digests were reported under `loaded` and
    compared against nothing, so `attested: true` was a claim about six fields
    wearing the name of the deployment. Only fields argued into the exempt set
    may go uncompared, and this asserts the set rather than the six.
    """
    contract = contract_in_lane(tmp_path, "shadow")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)
    report = gateway.attestation(matching_deployment(contract))
    loaded = set(report["loaded"])
    compared = set(report["matches"]) | set(report["unattested_fields"])
    assert loaded - compared == gateway._RECORDED_NOT_COMPARED
    assert report["attested"] is True
    for field in ("tokenizer_sha256", "serving_image_digest", "gateway_revision"):
        assert field in report["matches"], f"{field} is not compared"


def test_a_placeholder_expectation_withholds_attestation(tmp_path, monkeypatch):
    """An unmeasured gate is a reason to withhold, not a detail beneath one.

    This is the state of the tree: the tokenizer manifest is regenerated from
    whatever the GPU loads, and until then there is nothing to compare a
    measurement against. Treating that absence as agreement is how a deploy gate
    passes without being run.
    """
    import json as _json
    data = _json.loads(contract_path().read_text())
    data["runtime_requirements"]["qwen_overlay"] = "shadow"
    data["output_contract"]["tokenizer_manifest_sha256"] = "tok" * 21 + "1"
    data["versions"]["serving_image_digest"] = "sha256:serving"
    copy = tmp_path / "compiled_semantic_contract_v1.json"
    copy.write_text(_json.dumps(data))
    contract = SemanticContract(copy)
    monkeypatch.setattr(gateway, "_contract", lambda: contract)
    good = gateway.attestation(matching_deployment(contract))
    assert good["attested"] is True

    data["output_contract"]["tokenizer_manifest_sha256"] = \
        "required_from_pinned_deployment_not_yet_measured"
    copy.write_text(_json.dumps(data))
    stale = SemanticContract(copy)
    monkeypatch.setattr(gateway, "_contract", lambda: stale)
    report = gateway.attestation(matching_deployment(stale))
    assert report["attested"] is False
    assert "tokenizer_sha256" in report["unattested_fields"]
    assert "tokenizer_sha256" not in report["matches"]


def test_a_container_answering_with_other_weights_is_refused(tmp_path, monkeypatch):
    """The runtime block is measured by the container that produced the answer.

    Every other check compares one declaration against another. This is the one
    that compares a measurement, so it is the one that can catch an endpoint
    serving weights nobody asked for.
    """
    contract = contract_in_lane(tmp_path, "shadow")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)
    expected = contract.attestation()

    honest = dict(valid_response(contract=contract))
    honest["runtime"] = matching_runtime(contract)
    result = gateway.extract(REQUEST, transport=CountingTransport(response=honest),
                             deployment=matching_deployment(contract))
    assert result["outcome"] == "succeeded"

    drifted = dict(honest)
    drifted["runtime"] = dict(honest["runtime"], model_revision="some-other-commit")
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract(REQUEST, transport=CountingTransport(response=drifted),
                        deployment=matching_deployment(contract), max_attempts=1)
    assert refusal.value.code == "contract_mismatch"
    assert "model_revision" in refusal.value.detail
