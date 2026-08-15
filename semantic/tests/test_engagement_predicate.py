"""Watching and doing are different claims, and the scorer has to tell them apart.

**Written before the data exists, which is why it exists.** Measured over both
live accounts on 2026-08-15: zero mappings onto any `activity` concept, zero
HealthKit observations in the vault, and `healthkit.workout` weighted 0.0. So
the participation branch has nothing real to run on, and a live re-score would
exercise exactly one side of the rule — the side that answers `affinity_to`.

*A predicate is not believed until it has been seen answering both ways*, and
here only a stub can show that today. What these assert is **which predicate
reached `INSERT_ASSERTION`**, not a score: the arithmetic is checked elsewhere
and was never where this kind of defect lives.

The fourth test is the one that would be forgotten. A concept whose predicate
changes is a *new assertion row*, so the person's answer — recorded against the
old row, and against the old predicate — has to follow it, or a background job
quietly puts a suppressed term back on their page.
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
    worker = os.path.join(REPOSITORY, "aws", "worker")
    path = os.path.join(worker, "score.py")
    if not os.path.exists(path):
        pytest.skip("worker not present")
    if worker not in sys.path:
        sys.path.insert(0, worker)
    spec = importlib.util.spec_from_file_location("written_worker_engagement", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeCursor:
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
        self.rowcount = len(self._rows)

    def executemany(self, sql: str, rows) -> None:
        for row in rows:
            self.state.executed.append((sql, row))

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return self._rows


class FakeConnection:
    """Keyed on the module's SQL constants, so a rewritten query fails loudly."""

    def __init__(self, module, aggregates, labels, superseded=None) -> None:
        self.module = module
        self.aggregates = aggregates
        self.labels = labels
        self.superseded = superseded or []
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
        if sql is m.SUPPRESSION_TRANSFER:
            return []
        if sql is m.FIND_ASSERTION:
            return []
        if sql is m.INSERT_ASSERTION:
            return [{"id": f"assertion-{params.get('concept')}"}]
        if sql is m.DEMOTE_OTHER_PREDICATES:
            return list(self.superseded)
        if sql is m.INSERT_SCORE_VERSION:
            return [{"id": f"version-{params.get('concept', 'x')}"}]
        if sql is m.EVIDENCE:
            return []
        return []

    def statements(self, sql: str) -> list[dict]:
        return [params for statement, params in self.executed if statement is sql]


def aggregate(concept_id: str, *, participation=False, spectating=False,
              weight: float = 40.0) -> dict:
    return {
        "concept_id": concept_id, "total_weight": weight,
        "observation_count": 12, "mapping_count": 12,
        "breadth": 1, "source_count": 1,
        "mapping_agreement": 1.0, "evidence_quality": 1.0,
        "has_participation_evidence": participation,
        "has_spectating_evidence": spectating,
    }


def label(concept_id: str, kind: str, key: str | None = None) -> dict:
    return {
        "id": concept_id, "concept_kind": kind,
        "concept_key": key or f"{kind}:{concept_id}",
        "preferred_label": concept_id,
    }


def run(module, aggregates, labels, superseded=None):
    connection = FakeConnection(module, aggregates, labels, superseded)
    counts = module.score_user(
        connection, "user-1", "run-1", "version-1", "2026-08-15T00:00:00Z")
    return connection, counts


def predicates_written(module, connection) -> dict[str, str]:
    return {
        params["concept"]: params["predicate"]
        for params in connection.statements(module.INSERT_ASSERTION)
    }


def test_a_workout_says_the_person_does_it(score):
    """Involvement evidence, and the claim is participation."""
    connection, counts = run(
        score,
        [aggregate("soccer", participation=True)],
        [label("soccer", "activity")],
    )
    assert predicates_written(score, connection)["soccer"] == \
        score.PARTICIPATION_PREDICATE
    assert counts[score.PARTICIPATION_PREDICATE] == 1


def test_a_subscription_says_the_person_watches_it(score):
    """Viewing evidence, and the claim says so rather than saying "likes"."""
    connection, _ = run(
        score,
        [aggregate("soccer", spectating=True)],
        [label("soccer", "activity")],
    )
    assert predicates_written(score, connection)["soccer"] == \
        score.SPECTATING_PREDICATE


def test_doing_outranks_watching(score):
    """Somebody who plays and also watches plays.

    Watching does not contradict the stronger, positive fact, so participation
    wins rather than the two competing or producing two claims about one concept.
    """
    connection, _ = run(
        score,
        [aggregate("soccer", participation=True, spectating=True)],
        [label("soccer", "activity")],
    )
    assert predicates_written(score, connection)["soccer"] == \
        score.PARTICIPATION_PREDICATE


def test_unmarked_evidence_stays_an_affinity(score):
    """A saved track is neither watching nor doing, and saying so is the point.

    This is the branch every activity takes today, and it must not drift into
    guessing one of the other two.
    """
    connection, _ = run(
        score,
        [aggregate("pottery")],
        [label("pottery", "activity")],
    )
    assert predicates_written(score, connection)["pottery"] == \
        score.AFFINITY_PREDICATE


def test_only_an_activity_is_asked_the_question(score):
    """You do not participate in Bach.

    A creator, a work and a topic keep `affinity_to` whatever the evidence is
    marked, because there is nothing to watch or do about them — and the marks
    would otherwise leak through YouTube, which attests all three.
    """
    connection, _ = run(
        score,
        [aggregate("bach", spectating=True),
         aggregate("hearthstone", spectating=True),
         aggregate("archaeology", participation=True)],
        [label("bach", "creator"), label("hearthstone", "work"),
         label("archaeology", "topic")],
    )
    written = predicates_written(score, connection)
    assert set(written.values()) == {score.AFFINITY_PREDICATE}


def test_a_trip_is_exempt_by_key(score):
    """`travel:*` is `concept_kind = 'activity'` and is not an engagement question.

    It cannot reach the loop in production — calendar rows may not enter
    `observation_mappings` at all — and the exemption is written down anyway,
    because a rule resting on another rule's side effect is one nobody can read.
    """
    connection, _ = run(
        score,
        [aggregate("tokyo", spectating=True)],
        [label("tokyo", "activity", key="travel:tokyo")],
    )
    assert predicates_written(score, connection)["tokyo"] == \
        score.AFFINITY_PREDICATE


def test_the_sweep_names_every_predicate_it_could_have_written(score):
    """An assertion the sweep cannot name is one no re-score can withdraw.

    Both demotion statements took a single predicate while `affinity_to` was the
    only thing written, and leaving them that way would have made an engagement
    claim permanent.
    """
    connection, _ = run(
        score, [aggregate("soccer", participation=True)],
        [label("soccer", "activity")])
    sweep = connection.statements(score.DEMOTE_UNSCORED_ASSERTIONS)
    assert sweep, "the sweep did not run"
    assert set(sweep[0]["predicates"]) == set(score.ASSERTABLE_PREDICATES)


def test_a_changed_predicate_carries_the_persons_answer(score):
    """The one that would be forgotten.

    A concept moving from `affinity_to` to `follows_activity` is a new row under
    a new predicate, and *both* records of a person's decision are keyed on
    something that just changed: the preference on the assertion id, the
    suppression on the predicate. Left alone, a re-score puts a term somebody
    struck off back on their page.
    """
    connection, counts = run(
        score,
        [aggregate("soccer", spectating=True)],
        [label("soccer", "activity")],
        superseded=[{"id": "old-assertion", "predicate_key": "affinity_to"}],
    )
    assert counts["repredicated"] == 1

    carried = connection.statements(score.CARRY_PREFERENCE)
    assert carried, "the preference was not carried to the new assertion"
    assert carried[0]["from_assertion"] == "old-assertion"
    assert carried[0]["to_assertion"] == "assertion-soccer"

    suppressions = connection.statements(score.CARRY_SUPPRESSION)
    assert suppressions, "the suppression was not carried to the new predicate"
    assert suppressions[0]["from_predicate"] == "affinity_to"
    assert suppressions[0]["keep"] == score.SPECTATING_PREDICATE


def test_nothing_is_carried_when_nothing_was_superseded(score):
    """It copies and never invents.

    The ordinary case is a concept keeping its predicate, and that must touch
    neither preferences nor suppressions.
    """
    connection, counts = run(
        score, [aggregate("soccer", spectating=True)],
        [label("soccer", "activity")], superseded=[])
    assert "repredicated" not in counts
    assert connection.statements(score.CARRY_PREFERENCE) == []
    assert connection.statements(score.CARRY_SUPPRESSION) == []
