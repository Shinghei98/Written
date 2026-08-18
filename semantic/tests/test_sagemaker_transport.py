"""The async transport: no input object, and a delete that fails withholds the answer."""
from __future__ import annotations

import importlib.util
import json
import pathlib

import pytest

from written_ontology import gateway

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def module():
    spec = importlib.util.spec_from_file_location(
        "sagemaker_transport", REPOSITORY / "aws" / "gateway" / "sagemaker_transport.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


ANSWER = json.dumps({
    "choices": [{"finish_reason": "stop",
                 "message": {"content": json.dumps({"schema_version": "x", "items": []})}}],
    "usage": {"completion_tokens": 7},
}).encode()


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
    transport(module, s3, runtime).complete({"input": {}}, 5)
    assert s3.put == [], "the transport created an input object"
    assert "Body" in runtime.calls[0]
    assert "InputLocation" not in runtime.calls[0]


def test_the_answer_is_deleted_before_it_is_parsed(module):
    s3 = FakeS3({"async/out/answer.json": ANSWER})
    result = transport(module, s3, FakeRuntime()).complete({"input": {}}, 5)
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
        transport(module, s3, FakeRuntime()).complete({"input": {}}, 5)


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
        transport(module, s3, FakeRuntime()).complete({"input": {}}, 5)
    assert s3.deleted == ["async/fail/answer.json"]
