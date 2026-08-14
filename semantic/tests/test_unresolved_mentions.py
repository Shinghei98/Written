"""A term that matched nothing must be written down, and only for some sources.

**This is the difference between a system that can learn what it is missing and
one that can only count it.** `exact_terms_only` discards every term absent from
the alias graph, and until `record_mentions` existed the only trace was the
integer `no_exact_alias` — 2,881 on one real run, which says how many were lost
and nothing whatever about which. The resolver's own docstring claims unresolved
terms are "emitted anyway ... the input to `EmergentTermMiner`", and the 0.02
incidental-performer weight is justified by keeping a term alive for the same
reason; both were paying for something deleted 800 lines later.

**The allow-list is the part worth testing.** A mention is a raw string out of
somebody's library, and three sources may not be written for three different
reasons — Spotify because IV.2.1.a forbids ingesting its Content into a model,
YouTube because III.E.4's 30-day sweep covers `observations` and not this table,
every calendar because titles never reach the vault at all. Getting that list
wrong is silent in both directions: too narrow and the vocabulary never grows,
too wide and a retention obligation quietly stops being true.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the suite.
"""

from __future__ import annotations

import importlib.util
import os
import sys

import pytest

from written_ontology.models import Term

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def resolve():
    worker = os.path.join(REPOSITORY, "aws", "worker")
    path = os.path.join(worker, "resolve.py")
    if not os.path.exists(path):
        pytest.skip("worker resolver not present")
    # `tools/` too: `build.sh` flattens the bundle, so `resolve` imports the
    # music dictionary by bare module name.
    tools = os.path.join(REPOSITORY, "tools")
    for directory in (worker, tools):
        if directory not in sys.path:
            sys.path.insert(0, directory)
    spec = importlib.util.spec_from_file_location("written_worker_resolve_mentions", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Recorder:
    """A connection that fails if it is used, and remembers if it was.

    `record_mentions` must decide what to write *before* opening a cursor, so a
    refused source costs no round trip — and, more to the point, so a test can
    prove the refusal happened rather than inferring it from a count.
    """

    def __init__(self):
        self.rows = []

    def cursor(self):
        recorder = self

        class Cursor:
            def __enter__(self_inner):
                return self_inner

            def __exit__(self_inner, *args):
                return False

            def executemany(self_inner, _statement, rows):
                recorder.rows.extend(rows)

        return Cursor()


class FakeObservation:
    def __init__(self, source: str, identifier: str = "obs-1"):
        self.id = identifier
        self.source = source


def term(text: str = "Some Performer") -> Term:
    return Term(
        text=text,
        normalized=text.casefold(),
        role="creator",
        source_field="primary_performer",
        type_hint="creator",
    )


def test_apple_music_terms_are_recorded(resolve):
    connection = Recorder()
    written = resolve.record_mentions(
        connection, "user-1", [(FakeObservation("apple_music"), term())]
    )
    assert written == 1
    assert connection.rows[0]["mention_text"] == "Some Performer"
    assert connection.rows[0]["user_id"] == "user-1"
    # Recording a term and licensing its promotion are two decisions.
    assert "safe_for_global_mining" not in connection.rows[0]


@pytest.mark.parametrize(
    "source, why",
    [
        ("spotify", "IV.2.1.a forbids ingesting Spotify Content into a model"),
        ("youtube", "III.E.4's 30-day sweep does not cover this table"),
        ("apple_calendar", "titles never reach the vault"),
        ("google_calendar", "titles never reach the vault"),
        ("outlook_calendar", "titles never reach the vault"),
        ("healthkit", "not a source of names"),
    ],
)
def test_refused_sources_are_never_written(resolve, source, why):
    """And refused without touching the connection at all."""
    connection = Recorder()
    written = resolve.record_mentions(
        connection, "user-1", [(FakeObservation(source), term())]
    )
    assert written == 0, why
    assert connection.rows == [], why


def test_the_allow_list_is_exactly_these_four(resolve):
    """An exact set, so a source added later is refused by omission.

    The failure mode of a deny-list is silence; this is the assertion that keeps
    it an allow-list.
    """
    assert resolve.MINEABLE_SOURCES == frozenset(
        {"apple_music", "music_library", "apple_podcasts", "podcast"}
    )


def test_a_term_with_no_text_is_not_written(resolve):
    connection = Recorder()
    empty = Term(text="", normalized="", role="creator", source_field="x")
    written = resolve.record_mentions(
        connection, "user-1", [(FakeObservation("apple_music"), empty)]
    )
    assert written == 0
    assert connection.rows == []


def test_a_mixed_batch_writes_only_the_permitted_half(resolve):
    """The realistic case: one account, several sources, one run."""
    connection = Recorder()
    written = resolve.record_mentions(
        connection,
        "user-1",
        [
            (FakeObservation("apple_music", "a"), term("Kept One")),
            (FakeObservation("spotify", "b"), term("Refused One")),
            (FakeObservation("podcast", "c"), term("Kept Two")),
            (FakeObservation("youtube", "d"), term("Refused Two")),
        ],
    )
    assert written == 2
    assert [row["mention_text"] for row in connection.rows] == ["Kept One", "Kept Two"]
