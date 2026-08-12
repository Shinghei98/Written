"""The review tool must build the classifier the Lambda builds.

**Its entire value is that it reproduces a decision it cannot read back.**
`observations.normalized_payload` carries four keys and no title — the private
title *"participates only in the HMAC lineage and is not returned"* — and
`source_item_hmac` is salted with a KMS key only the classifier's role may use.
So §10's *"review every Calendar promotion"* cannot be answered from the vault,
and `tools/calendar_review.py` re-derives each decision from the legacy row
instead.

That only works while the two classifiers are the same classifier. Four offline
catalogs decide whether a booking has a recognised vendor and whether a carrier
code is real; construct without one and rows silently reclassify — the tool
would produce a confident review of a classifier nobody deployed, which is the
one way this gate could be worse than not running it.

So this reads the constructor arguments out of `aws/classifier/handler.py` and
fails if the tool's differ. Comparing the *arguments* rather than the decisions
is deliberate: the handler needs KMS and an IAM role, so importing it here is
not possible, and the catalogs are the only thing that can drift silently.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import re
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


def constructor_arguments(source: str) -> set[str]:
    """The keyword names passed to `CalendarClassifier(...)` in one file.

    **Slice from the paren, not from the name.** Starting at `CalendarClassifier`
    the depth counter is 0 on the first character, so it "closed" immediately and
    returned an empty set — for both files, which compared equal. The check
    passed while a catalog was deliberately deleted, which is the failure a
    perturbation exists to catch and the only reason it was found.
    """
    start = source.index("CalendarClassifier(") + len("CalendarClassifier")
    body = source[start:]
    depth = 0
    for index, char in enumerate(body):
        depth += char == "("
        depth -= char == ")"
        if depth == 0:
            body = body[: index + 1]
            break
    names = set(re.findall(r"(\w+)\s*=", body))
    if not names:
        raise AssertionError("no keyword arguments found — the extractor is broken")
    return names


@pytest.fixture(scope="module")
def review_tool():
    path = os.path.join(REPOSITORY, "tools", "calendar_review.py")
    if not os.path.exists(path):
        pytest.skip("review tool not present")
    spec = importlib.util.spec_from_file_location("written_calendar_review", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_tool_and_the_lambda_build_the_same_classifier(review_tool):
    handler = pathlib.Path(REPOSITORY, "aws", "classifier", "handler.py").read_text()
    tool = pathlib.Path(REPOSITORY, "tools", "calendar_review.py").read_text()
    assert constructor_arguments(tool) == constructor_arguments(handler)


def test_it_reads_the_summary_view_and_not_the_table():
    """`distilled_records` is append-only across runs; the view is current state.

    The first version queried the table and counted history. David's 106 events
    are 158 rows there, so the review reported **9 promotions against the
    vault's 5** — eight flight segments for four flights, one per distillation.
    Demo matched at 9 and 9 on the same code because its four duplicate rows
    happened not to be promotable, so the agreement check passed on one account
    and failed on the other; a single account would have shipped this.

    Asserted as text because the alternative is a live database. What can
    regress here is one identifier.
    """
    source = pathlib.Path(REPOSITORY, "tools", "calendar_review.py").read_text()
    assert "/rest/v1/summary_distilled_records?" in source
    assert "/rest/v1/distilled_records?" not in source


def test_a_structured_flight_is_promoted(review_tool):
    """The shape the four real promotions have, and the one that misled me.

    A flight title alone is not a segment: without `end` (or a duration) there
    is nothing to build one from, and the row falls past the flight branch to
    `excluded_unknown` — which reads exactly like the title not matching. Both
    halves are asserted so a future change cannot quietly make the title alone
    sufficient.
    """
    classifier = review_tool.classifier_for("test")
    row = {
        "source": "apple_calendar", "data_type": "event", "item_id": "1",
        "name": "FLIGHT to Los Angeles (UA 1103)", "detail": "", "creator": "",
    }

    complete = classifier.classify(
        {**row, "extra": "start=2026-11-02T09:00:00Z;end=2026-11-02T13:00:00Z"},
        calendar_metadata=None,
    )
    assert complete.included
    assert complete.flight_segment.destination_label == "Los Angeles"
    assert complete.flight_segment.carrier_code == "UA"

    open_ended = classifier.classify(
        {**row, "extra": "start=2026-11-02T09:00:00Z"}, calendar_metadata=None,
    )
    assert not open_ended.included


def test_the_hard_exclusions_still_precede_the_title(review_tool):
    """A ticket-shaped title must not buy its way past the boundary.

    `_SENSITIVE_RE` and friends run before any parsing, and the tool inherits
    that ordering by construction rather than by reimplementing it — which is
    the property worth a test, since the tool is what a person will read and
    believe.
    """
    classifier = review_tool.classifier_for("test")
    decision = classifier.classify({
        "source": "apple_calendar", "data_type": "event", "item_id": "2",
        "name": "Dentist", "detail": "", "creator": "",
        "extra": "start=2026-09-01T09:00:00Z;end=2026-09-01T10:00:00Z",
    }, calendar_metadata=None)
    assert not decision.included
    assert str(decision.disposition) == "excluded_sensitive"
