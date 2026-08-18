"""The async transport: no input object, and a delete that fails withholds the answer."""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

import pytest

from written_ontology import gateway

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def module():
    spec = importlib.util.spec_from_file_location(
        "sagemaker_transport", REPOSITORY / "aws" / "gateway" / "sagemaker_transport.py")
    loaded = importlib.util.module_from_spec(spec)
    # **Registered before it is executed.** `from __future__ import annotations`
    # makes every annotation a string, and a dataclass in the module resolves
    # them through `sys.modules[cls.__module__]` — which is None for a module
    # loaded by path and never registered. The failure is an AttributeError
    # inside dataclasses, nowhere near the cause.
    sys.modules[spec.name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


ANSWER = json.dumps({
    "choices": [{"finish_reason": "stop",
                 "message": {"content": json.dumps({"schema_version": "x", "items": []})}}],
    "usage": {"completion_tokens": 7},
}).encode()


#: The request schema requires `request_id`, so a payload without one is not a
#: simpler case of a real request — it is one the validator would never emit.
PAYLOAD = {"request_id": "req_abc123", "items": []}


class FakeS3:
    def __init__(self, objects, delete_raises=False):
        self.objects = dict(objects)
        self.deleted: list[str] = []
        self.put: list[str] = []
        self._delete_raises = delete_raises

    def head_object(self, Bucket, Key):
        if Key not in self.objects:
            raise RuntimeError("NoSuchKey")

    def get_object(self, Bucket, Key):
        class Body:
            def __init__(self, data): self._data = data
            def read(self): return self._data
        return {"Body": Body(self.objects[Key])}

    def delete_object(self, Bucket, Key):
        if self._delete_raises:
            raise RuntimeError("AccessDenied")
        self.deleted.append(Key)
        self.objects.pop(Key, None)

    def put_object(self, **kwargs):
        self.put.append(kwargs.get("Key"))


class FakeRuntime:
    def __init__(self):
        self.calls: list[dict] = []

    def invoke_endpoint_async(self, **kwargs):
        self.calls.append(kwargs)
        return {"OutputLocation": "s3://b/async/out/answer.json",
                "FailureLocation": "s3://b/async/fail/answer.json"}


def transport(module, s3, runtime, **kwargs):
    return module.SageMakerAsyncTransport(
        "written-qwen", "b", poll_interval_s=0,
        clients={"s3": s3, "sagemaker-runtime": runtime}, **kwargs)


def test_the_request_never_becomes_a_file(module):
    """`InvokeEndpointAsync` takes an inline Body; only EndpointName is required.

    The first version wrote the request to S3 on the assumption that async
    inference had no inline path. It does, and the difference is one whole
    retention surface that now does not exist.
    """
    s3 = FakeS3({"async/out/answer.json": ANSWER})
    runtime = FakeRuntime()
    transport(module, s3, runtime).complete(PAYLOAD, 5)
    assert s3.put == [], "the transport created an input object"
    assert "Body" in runtime.calls[0]
    assert "InputLocation" not in runtime.calls[0]


def test_the_answer_is_deleted_before_it_is_parsed(module):
    s3 = FakeS3({"async/out/answer.json": ANSWER})
    result = transport(module, s3, FakeRuntime()).complete(PAYLOAD, 5)
    assert s3.deleted == ["async/out/answer.json"]
    assert result["output_tokens"] == 7


def test_a_failed_deletion_withholds_the_answer(module):
    """The model answered and the result is refused anyway.

    Committing semantics derived from text we cannot show we stopped holding is
    the trade this refuses; the lifecycle rule is a backstop for a process that
    died, not a licence to proceed past it.
    """
    s3 = FakeS3({"async/out/answer.json": ANSWER}, delete_raises=True)
    with pytest.raises(gateway.RetentionFailure):
        transport(module, s3, FakeRuntime()).complete(PAYLOAD, 5)


def test_the_gateway_names_it_and_does_not_retry(module, monkeypatch, tmp_path):
    from written_ontology.mention_extract_v2 import RequestItem
    from test_gateway import contract_in_lane, matching_deployment

    contract = contract_in_lane(tmp_path, "shadow")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)

    class Failing:
        def __init__(self): self.calls = 0
        def complete(self, payload, timeout_s):
            self.calls += 1
            raise gateway.RetentionFailure("AccessDenied")

    failing = Failing()
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract([RequestItem(0, {"title": "Midnight"})],
                        transport=failing, deployment=matching_deployment(contract),
                        max_attempts=3)
    assert refusal.value.code == "retention_failed"
    # A second call would leave a second object beside the first.
    assert failing.calls == 1


def test_a_failure_object_is_deleted_too(module):
    """It is provider text as much as the answer is."""
    s3 = FakeS3({"async/fail/answer.json": b"{}"})
    with pytest.raises(RuntimeError):
        transport(module, s3, FakeRuntime()).complete(PAYLOAD, 5)
    assert s3.deleted == ["async/fail/answer.json"]


# ---------------------------------------------------------------------------
# Submitted once
# ---------------------------------------------------------------------------

def test_the_identifier_is_the_request_and_not_a_new_one(module):
    """Two submissions of the same request carry the same id.

    The version this replaced called `uuid.uuid4()` inside the call, so the same
    work submitted twice was indistinguishable from two pieces of work. Deriving
    the id from `request_id` makes a duplicate *visible* — which is the only way
    anything downstream can notice one.
    """
    runtime = FakeRuntime()
    first = transport(module, FakeS3({}), runtime).submit(PAYLOAD, 5)
    second = transport(module, FakeS3({}), runtime).submit(PAYLOAD, 5)
    assert first.inference_id == second.inference_id == "req_abc123"
    assert runtime.calls[0]["InferenceId"] == "req_abc123"


def test_a_request_with_no_id_is_refused_rather_than_given_one(module):
    """The fallback that would be convenient here is the defect itself."""
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        transport(module, FakeS3({}), FakeRuntime()).submit({"items": []}, 5)
    assert refusal.value.code == "contract_mismatch"


def test_polling_out_of_time_says_so_and_enqueues_nothing_more(module):
    """No answer ever appears. One job is submitted, and it stays one."""
    runtime = FakeRuntime()
    with pytest.raises(gateway.InferenceInFlight) as flight:
        transport(module, FakeS3({}), runtime).complete(PAYLOAD, 0.01)
    assert len(runtime.calls) == 1
    assert flight.value.ticket.output_key == "async/out/answer.json"


def test_a_ticket_is_collected_without_submitting_again(module):
    """The answer arrives late; collecting it is not a second job."""
    runtime = FakeRuntime()
    s3 = FakeS3({})
    holder = transport(module, s3, runtime)
    with pytest.raises(gateway.InferenceInFlight) as flight:
        holder.complete(PAYLOAD, 0.01)
    s3.objects["async/out/answer.json"] = ANSWER          # the endpoint finishes
    result = holder.collect(flight.value.ticket, 5)
    assert result["output_tokens"] == 7
    assert s3.deleted == ["async/out/answer.json"]
    assert len(runtime.calls) == 1, "collecting re-submitted the work"


# ---------------------------------------------------------------------------
# ...and the rule answers the other way too
# ---------------------------------------------------------------------------

def test_the_gateway_does_not_retry_work_already_accepted(module, monkeypatch,
                                                          tmp_path):
    from written_ontology.mention_extract_v2 import RequestItem
    from test_gateway import contract_in_lane, matching_deployment

    contract = contract_in_lane(tmp_path, "shadow")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)

    class InFlight:
        def __init__(self): self.calls = 0
        def complete(self, payload, timeout_s):
            self.calls += 1
            raise gateway.InferenceInFlight(object())

    transport_ = InFlight()
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract([RequestItem(0, {"title": "Midnight"})],
                        transport=transport_,
                        deployment=matching_deployment(contract), max_attempts=3)
    assert refusal.value.code == "timeout"
    assert transport_.calls == 1, "an accepted job was submitted again"


def test_a_timeout_before_submission_is_still_retried(module, monkeypatch,
                                                      tmp_path):
    """The other direction, and it is why the two exceptions are not one.

    Nothing was enqueued, so nothing is duplicated by asking again — and a rule
    that has only ever been seen refusing is not one to believe.
    """
    from written_ontology.mention_extract_v2 import RequestItem
    from test_gateway import contract_in_lane, matching_deployment

    contract = contract_in_lane(tmp_path, "shadow")
    monkeypatch.setattr(gateway, "_contract", lambda: contract)

    class NeverReached:
        def __init__(self): self.calls = 0
        def complete(self, payload, timeout_s):
            self.calls += 1
            raise TimeoutError("no socket")

    transport_ = NeverReached()
    with pytest.raises(gateway.GatewayRefusal) as refusal:
        gateway.extract([RequestItem(0, {"title": "Midnight"})],
                        transport=transport_,
                        deployment=matching_deployment(contract), max_attempts=3)
    assert refusal.value.code == "timeout"
    assert transport_.calls == 3, "an unaccepted call was not retried"
