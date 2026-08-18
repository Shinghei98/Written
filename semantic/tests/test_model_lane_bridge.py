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


def test_evaluation_reads_nothing_and_calls_nothing(overlay, monkeypatch):
    """**Fixture-only is about what may be read, not what may be written.**

    The earlier version called the model with a real account's evidence and
    merely declined to write the mention. `0239` raises three separate refusals
    on that shape — an evaluation invocation may not name a user, an
    observation, or retained source text — so the database would have rejected
    the whole call *after* the model had been paid for.

    There is no fixture corpus yet, so the honest behaviour is to decline. This
    asserts the strong property: neither the evidence reader nor the lane is
    reached at all.
    """
    def refuse_read(*a, **k):
        raise AssertionError("evaluation read a person's rows")

    class Lane:
        def __init__(self, *a, **k):
            raise AssertionError("evaluation called the model")

    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", refuse_read)
    monkeypatch.setattr(overlay, "_items_for", refuse_read)

    result = overlay._propose_and_write(
        FakeConnection(), _job(), "evaluation", "u-1", "req_x", None, None)
    assert result["status"] == "no_op"
    assert result["abstained"] is True
    # **No free-text reason.** `worker_job_result_is_safe_v03` permits a fixed
    # set of keys and would refuse one, so the explanation is a log line.
    assert set(result) <= {"status", "abstained", "item_count", "created_count"}


def test_shadow_writes_the_mention(overlay, monkeypatch):
    """The other direction of the same rule."""
    connection = FakeConnection()

    class Lane:
        def __init__(self, *a, **k): pass
        def propose(self, **kwargs): return proposal()

    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", lambda *a, **k: 0)
    monkeypatch.setattr(overlay, "_items_for",
                        lambda *a, **k: [_stub_item()])
    result = overlay._propose_and_write(
        connection, _job(), "shadow", "u-1", "req_x", None, None)
    # `created_count`, not `mentions_written`: the receipt vocabulary is closed.
    assert result["created_count"] == 1
    assert result["status"] == "succeeded"


def test_an_in_flight_call_defers_the_job(overlay, monkeypatch):
    """Scale-from-zero, and it is a queue state rather than a receipt.

    `in_flight` is not one of the nine status words the receipt schema permits,
    so it cannot be persisted as a result at all. It raises, and the runner
    defers — without writing `last_error` and without spending an attempt.
    """
    class Lane:
        def __init__(self, *a, **k): pass
        def propose(self, **kwargs):
            raise _INFLIGHT("req_resume")

    monkeypatch.setitem(sys.modules, "model_lane", _module_with(Lane))
    monkeypatch.setattr(overlay, "_file_evidence", lambda *a, **k: 0)
    monkeypatch.setattr(overlay, "_items_for",
                        lambda *a, **k: [_stub_item()])
    with pytest.raises(overlay.InferenceDeferred) as deferred:
        overlay._propose_and_write(
            FakeConnection(), _job(), "shadow", "u-1", "req_x", None, None)
    assert deferred.value.item_count == 1


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
    assert "reason" not in result


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


def _stub_item():
    """One item as `_items_for` builds it — **including its profile**.

    A stub without `source_profile` is not a simpler item: `_one_profile`
    refuses it, and rightly, since the profile decides which predicates the
    source may produce. `music_catalog` is what `music_library` maps to.
    """
    return {"item_index": 0, "fields": {"title": "x"},
            "observation_id": "o", "source_text_evidence_id": "e",
            "logical_extraction_key": "k", "source_profile": "music_catalog"}


def _job():
    class Job:
        id = "job-1"
        payload = {"user_id": "u-1", "job_id": "job-1"}
    return Job()
