"""The Step 5 bridge: two identities, and a mention that names what earned it.

The property worth proving is not that a mention gets written — that is easy to
arrange — but that **the worker writes it naming an invocation item it could not
have created**, and that an item which did not succeed contributes nothing. The
database enforces both (`0241`, `0243`, `guard_model_mention_lineage`); these
assert the handler does not rely on being caught.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys

import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def overlay():
    sys.path.insert(0, str(REPOSITORY / "aws" / "worker"))
    spec = importlib.util.spec_from_file_location(
        "overlay_under_test", REPOSITORY / "aws" / "worker" / "overlay.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeCursor:
    def __init__(self, sink): self.sink = sink
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def executemany(self, sql, rows): self.sink.extend(rows)
    def execute(self, sql, args=None): pass
    def fetchall(self): return []
    def fetchone(self): return None


class FakeConnection:
    def __init__(self): self.written: list[dict] = []
    def cursor(self): return FakeCursor(self.written)


def proposal(outcome="succeeded", mentions=(("Hearthstone", "title"),)):
    return {
        "invocation_id": "11111111-1111-4111-8111-111111111111",
        "lineage": [{
            "item_index": 0, "outcome": outcome,
            "item_id": "22222222-2222-4222-8222-222222222222",
            "observation_id": "33333333-3333-4333-8333-333333333333",
            "mention_count": len(mentions),
        }],
        "items": [{
            "item_index": 0,
            "mentions": [{"surface": s, "source_field": f,
                          "mention_role": "primary_subject",
                          "family_hypothesis": "game", "confidence": 0.9}
                         for s, f in mentions],
        }],
    }


def test_a_mention_names_the_item_that_earned_it(overlay):
    """The link the guard checks is written by the handler, not hoped for."""
    connection = FakeConnection()
    written = overlay._write_model_mentions(
        connection, "44444444-4444-4444-8444-444444444444", [], proposal())
    assert written == 1
    row = connection.written[0]
    assert row["model_invocation_item_id"] == "22222222-2222-4222-8222-222222222222"
    assert row["observation_id"] == "33333333-3333-4333-8333-333333333333"
    assert row["mention_text"] == "Hearthstone"
    # Normalised by the exact lane's own function, so a model mention and a
    # projection mention of the same string resolve to the same concept.
    assert row["normalized_text"] == overlay._normalize("Hearthstone")


def test_an_item_that_did_not_succeed_contributes_nothing(overlay):
    """A refusal is not evidence about a person, and the handler agrees.

    The check constraint refuses a mention count on a failed item and the
    trigger refuses the mention itself; this asserts the handler never gets
    that far, so the guard is a backstop rather than the mechanism.
    """
    connection = FakeConnection()
    for outcome in ("timeout", "schema_invalid", "semantic_abstention",
                    "missing_item"):
        assert overlay._write_model_mentions(
            connection, "44444444-4444-4444-8444-444444444444", [],
            proposal(outcome=outcome)) == 0
    assert connection.written == []


def test_the_request_id_is_stable_across_retries(overlay):
    """A retried job must collect its answer, not buy a second one."""
    class Job:
        id = "job-1"
        payload = {"user_id": "u-1", "job_id": "job-1"}
    first, second = overlay._request_id(Job()), overlay._request_id(Job())
    assert first == second and first.startswith("req_")

    class Other(Job):
        payload = {"user_id": "u-2", "job_id": "job-1"}
    assert overlay._request_id(Other()) != first


def test_evaluation_calls_the_model_and_writes_no_mention(overlay, monkeypatch):
    """Fixture-only, and the handler does not lean on the trigger to say so."""
    connection = FakeConnection()

    class Lane:
        def __init__(self, *a, **k): self.called = False
        def propose(self, **kwargs):
            self.called = True
            return proposal()

    lane = Lane()
    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", lambda *a, **k: 0)
    monkeypatch.setattr(overlay, "_items_for",
                        lambda *a, **k: [{"item_index": 0, "fields": {"title": "x"},
                                          "observation_id": "o", 
                                          "source_text_evidence_id": "e",
                                          "logical_extraction_key": "k"}])
    result = overlay._propose_and_write(
        connection, _job(), "evaluation", "u-1", "req_x", None, None)
    assert result["mentions_written"] == 0
    assert connection.written == []
    # It still records an invocation: an evaluation call happened and is
    # evidence, which is why the lane is asked at all.
    assert result["invocation_id"]


def test_shadow_writes_the_mention(overlay, monkeypatch):
    """The other direction of the same rule."""
    connection = FakeConnection()

    class Lane:
        def __init__(self, *a, **k): pass
        def propose(self, **kwargs): return proposal()

    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", lambda *a, **k: 0)
    monkeypatch.setattr(overlay, "_items_for",
                        lambda *a, **k: [{"item_index": 0, "fields": {"title": "x"},
                                          "observation_id": "o",
                                          "source_text_evidence_id": "e",
                                          "logical_extraction_key": "k"}])
    result = overlay._propose_and_write(
        connection, _job(), "shadow", "u-1", "req_x", None, None)
    assert result["mentions_written"] == 1


def test_an_in_flight_call_is_reported_not_retried(overlay, monkeypatch):
    """Scale-from-zero: the job comes back with an id, not with a second job."""
    class Lane:
        def __init__(self, *a, **k): pass
        def propose(self, **kwargs):
            raise _INFLIGHT("req_resume")

    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", lambda *a, **k: 0)
    monkeypatch.setattr(overlay, "_items_for",
                        lambda *a, **k: [{"item_index": 0, "fields": {"title": "x"},
                                          "observation_id": "o",
                                          "source_text_evidence_id": "e",
                                          "logical_extraction_key": "k"}])
    result = overlay._propose_and_write(
        FakeConnection(), _job(), "shadow", "u-1", "req_x", None, None)
    assert result["status"] == "in_flight"
    assert result["resume_request_id"] == "req_resume"


def test_no_evidence_is_not_a_failure(overlay, monkeypatch):
    """An empty call would record an invocation that asked nothing."""
    class Lane:
        def __init__(self, *a, **k): raise AssertionError("the lane was called")

    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", lambda *a, **k: 0)
    monkeypatch.setattr(overlay, "_items_for", lambda *a, **k: [])
    result = overlay._propose_and_write(
        FakeConnection(), _job(), "shadow", "u-1", "req_x", None, None)
    assert result["status"] == "no_op" and result["item_count"] == 0


# -- scaffolding ------------------------------------------------------------

import types  # noqa: E402


class _INFLIGHT(RuntimeError):
    def __init__(self, request_id):
        super().__init__(request_id)
        self.request_id = request_id


class _UNAVAILABLE(RuntimeError):
    pass


def _module_with(lane_class):
    module = types.ModuleType("model_lane")
    module.ModelLane = lane_class
    module.InFlight = _INFLIGHT
    module.LaneUnavailable = _UNAVAILABLE
    return module


def _job():
    class Job:
        id = "job-1"
        payload = {"user_id": "u-1", "job_id": "job-1"}
    return Job()
