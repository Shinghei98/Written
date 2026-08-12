"""A claim the scorer stops making has to stop being made.

**This is written against a defect that survived every other check.**
`score.py` could raise an assertion and could not lower one: the eligibility
test sat before the lookup, so `UPDATE_ASSERTION` was reachable only with
`state = 'eligible'`, and its own comment — *"an assertion that stops being
evidenced becomes `inactive`"* — described behaviour the control flow made
impossible. It was found by changing the scorer so hub concepts assert nothing,
deploying, re-scoring, and watching three hub assertions come back `eligible`
from a run that had not touched them.

Nothing caught it because nothing covers `score_user`: it wants a database, so
it had no unit test at all, and a live re-score is the slowest possible place to
learn that a claim is sticky. So this stubs the connection. **What it asserts is
the SQL that ran**, not a score — the arithmetic is already checked elsewhere,
and the bug was never in the arithmetic. It was in which statement executes.

Three shapes, and the third is why the sweep is a separate statement:

- a concept scored and no longer eligible — demoted inside the loop
- a concept not scored at all — demoted by the sweep, since it never reaches
  the loop to be noticed
- a run that scored nothing — demotes nothing, because a resolver that fell over
  must not read as somebody who likes nothing
"""

from __future__ import annotations

import importlib.util
import os
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def score():
    """`aws/worker/score.py` is a Lambda module, not an installed package."""
    worker = os.path.join(REPOSITORY, "aws", "worker")
    path = os.path.join(worker, "score.py")
    if not os.path.exists(path):
        pytest.skip("worker not present")
    if worker not in sys.path:
        sys.path.insert(0, worker)
    spec = importlib.util.spec_from_file_location("written_worker_score", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeCursor:
    """Answers by statement, and records every statement it was given.

    Keyed on the module's own SQL constants rather than on substrings, so a
    rewritten query fails loudly here instead of silently matching nothing and
    returning the default.
    """

    def __init__(self, state: "FakeConnection") -> None:
        self.state = state
        self.rowcount = 0
        self._rows: list[dict] = []

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *exc) -> bool:
        return False

    def execute(self, sql: str, params: dict | None = None) -> None:
        self.state.executed.append((sql, params or {}))
        self._rows = self.state.answer_for(sql, params or {})
        self.rowcount = self.state.rowcount_for(sql, params or {})

    def executemany(self, sql: str, rows) -> None:
        for row in rows:
            self.state.executed.append((sql, row))

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return self._rows


class FakeConnection:
    def __init__(self, module, aggregates, labels, existing_assertions) -> None:
        self.module = module
        self.aggregates = aggregates
        self.labels = labels
        self.existing = existing_assertions
        self.executed: list[tuple[str, dict]] = []

    def cursor(self) -> FakeCursor:
        return FakeCursor(self)

    def answer_for(self, sql: str, params: dict) -> list[dict]:
        m = self.module
        if sql is m.RUN_POLICY_VERSION:
            return [{"recency_policy_version": "written-recency-v1"}]
        if sql is m.CONCEPT_LABELS:
            return self.labels
        if sql is m.CONNECTED_SOURCES:
            return [{"n": 2}]
        if sql is m.AGGREGATE:
            return self.aggregates
        if sql is m.FIND_ASSERTION:
            concept = params.get("concept")
            if concept in self.existing:
                return [{"id": f"assertion-{concept}"}]
            return []
        if sql is m.INSERT_ASSERTION:
            return [{"id": f"assertion-{params.get('concept')}"}]
        if sql is m.INSERT_SCORE_VERSION:
            return [{"id": f"version-{params.get('concept', 'x')}"}]
        if sql is m.EVIDENCE:
            return []
        return []

    def rowcount_for(self, sql: str, params: dict) -> int:
        m = self.module
        # The demotions report what they touched, which is what the run metrics
        # count. A stub that always answered 0 would let a broken `rowcount`
        # read as "nothing needed demoting".
        if sql is m.DEMOTE_ASSERTION:
            return 1 if params.get("concept") in self.existing else 0
        if sql is m.DEMOTE_UNSCORED_ASSERTIONS:
            scored = set(params.get("scored") or [])
            return len([c for c in self.existing if c not in scored])
        return 0

    def statements(self, sql: str) -> list[dict]:
        return [params for statement, params in self.executed if statement is sql]


def aggregate(concept_id: str, weight: float) -> dict:
    return {
        "concept_id": concept_id, "total_weight": weight,
        "observation_count": 12, "mapping_count": 12,
        "breadth": 1, "source_count": 1,
        "mapping_agreement": 1.0, "evidence_quality": 1.0,
    }


def label(concept_id: str, kind: str) -> dict:
    return {
        "id": concept_id, "concept_kind": kind,
        "concept_key": f"{kind}:{concept_id}",
        "preferred_label": concept_id,
    }


def run(module, aggregates, labels, existing) -> tuple[FakeConnection, dict]:
    connection = FakeConnection(module, aggregates, labels, set(existing))
    counts = module.score_user(
        connection, "user-1", "run-1", "version-1", "2026-08-12T00:00:00Z")
    return connection, counts


def test_a_concept_that_falls_below_the_bar_is_demoted(score):
    """The shape the live re-score would have shown, had anything been watching."""
    connection, counts = run(
        score,
        [aggregate("faded", 0.05)],
        [label("faded", "creator")],
        existing={"faded"},
    )
    demotions = connection.statements(score.DEMOTE_ASSERTION)
    assert [d["concept"] for d in demotions] == ["faded"]
    assert counts["demoted"] == 1
    # And it did not also try to raise one.
    assert connection.statements(score.INSERT_ASSERTION) == []


def test_a_hub_is_scored_and_never_asserted(score):
    """`NEVER_ASSERTED_KINDS` has to withdraw as well as withhold.

    A kind that stops asserting only for concepts nobody had yet asserted is a
    rule that arrives too late for exactly the concepts it was written for.
    """
    connection, counts = run(
        score,
        [aggregate("music", 40.0)],
        [label("music", "hub")],
        existing={"music"},
    )
    assert counts["scored"] == 1
    assert counts["container_kind"] == 1
    assert [d["concept"] for d in connection.statements(score.DEMOTE_ASSERTION)] \
        == ["music"]
    assert connection.statements(score.INSERT_ASSERTION) == []


def test_a_concept_nobody_scored_is_swept(score):
    """The case with no iteration to hang a demotion on.

    A banned term, a retired concept or a disconnected source removes the
    concept from the aggregate entirely, so the loop never sees it. Its
    assertion would stand forever on evidence that no longer exists.
    """
    connection, counts = run(
        score,
        [aggregate("kept", 40.0)],
        [label("kept", "creator")],
        existing={"kept", "vanished"},
    )
    sweeps = connection.statements(score.DEMOTE_UNSCORED_ASSERTIONS)
    assert len(sweeps) == 1
    assert sweeps[0]["scored"] == ["kept"]
    assert counts["demoted"] == 1


def test_a_run_that_scored_nothing_withdraws_nothing(score):
    """The guard that stops a bad run erasing a person.

    An empty aggregate means the resolver found nothing — a fallen-over run, an
    ontology version with no concepts, a source disconnected mid-flight. Sweeping
    on that would retire every claim somebody has, and the sweep's own SQL would
    do it correctly and catastrophically: no concept is in an empty scored list.
    """
    connection, counts = run(score, [], [], existing={"kept", "also_kept"})
    assert connection.statements(score.DEMOTE_UNSCORED_ASSERTIONS) == []
    assert connection.statements(score.DEMOTE_ASSERTION) == []
    assert counts["demoted"] == 0


def test_an_eligible_concept_is_still_asserted(score):
    """The control. Everything above removes claims; this proves one survives."""
    connection, counts = run(
        score,
        [aggregate("strong", 40.0)],
        [label("strong", "creator")],
        existing=set(),
    )
    assert counts["eligible"] == 1
    assert [i["concept"] for i in connection.statements(score.INSERT_ASSERTION)] \
        == ["strong"]
    assert connection.statements(score.DEMOTE_ASSERTION) == []
