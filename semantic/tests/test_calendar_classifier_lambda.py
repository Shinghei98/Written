"""The Calendar classifier Lambda, against the events the app actually captures.

**Two shapes meet here and neither side knows about the other**, as with the
HealthKit adapter: the app writes a typed `CalendarPayload`, and
`CalendarClassifier.classify` reads the legacy row — `name`, `detail` and a
semicolon `extra` string. Every failure mode of that join is silent. A mistyped
key or a wrong casing reads as *absent*, which the classifier reports as
`excluded_unknown` — a calendar that looks like it contained nothing worth
keeping, which is also what a correctly-classified private calendar looks like.

So these assert two things a comment cannot: that the fields survive the join,
and that the projection is byte-for-byte what
`private_observation_projection_is_valid_v03` compares against. That constraint
tests `normalized_payload = jsonb_build_object(...)` — equality, not
containment — so one extra key refuses the row.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the
repository-integration suite.
"""

import importlib.util
import os
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def lambda_module():
    path = os.path.join(REPOSITORY, "aws", "classifier", "handler.py")
    if not os.path.exists(path):
        pytest.skip("classifier lambda not present")
    boto3 = pytest.importorskip("boto3")  # noqa: F841 - imported by the module
    os.environ.setdefault("LINEAGE_KEY_ARN", "arn:aws:kms:us-east-1:0:key/test")
    spec = importlib.util.spec_from_file_location("written_calendar_lambda", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    # **Never reaches KMS.** The key is derived once and cached at module scope,
    # so seeding the cache is enough and no AWS client is stubbed.
    module._lineage_key = b"a-test-lineage-key"
    return module


def classify(module, payload, calendar=None):
    row = module.legacy_row(payload, "event-1")
    decision = module.classifier_for("user-1").classify(
        row, calendar_metadata=calendar
    )
    return decision, module.project(decision)


FLIGHT = {
    # **The canonical form, and it is narrow on purpose.** `_FLIGHT_TITLE_RE`
    # matches `FLIGHT to <destination> (<CARRIER><NUMBER>)` and nothing else —
    # not "UA 1103 to Los Angeles", not "United 1103 SFO→LAX", which is what an
    # airline actually writes into a calendar. Anything else is
    # `excluded_unknown`, which is the safe direction (nothing is invented) but
    # means the flight path is close to dead on real device data until something
    # normalizes titles into this shape.
    #
    # The space before the number is load-bearing too: `[A-Z0-9]{2,3}` is greedy,
    # so `(UA1103)` parses as carrier `UA1` and answers `unknown_carrier_code`.
    "title": "FLIGHT to Los Angeles (UA 1103)",
    "location": "San Francisco",
    "startsAt": "2026-11-14T18:30:00Z",
    "endsAt": "2026-11-14T21:05:00Z",
    "isBooked": True,
    "calendarType": "caldav",
    "calendarName": "Personal",
}


def test_a_flight_becomes_a_travel_itinerary(lambda_module):
    """The case the Calendar source exists for.

    A ticketing site writes this in by itself, which is what `booked=1` records
    and what makes it a stronger claim than anything a person follows.
    """
    decision, projection = classify(lambda_module, dict(FLIGHT))

    assert projection["classification_state"] == "candidate"
    assert projection["artifact_type"] == "travel_itinerary"
    # 64 lowercase hex, which is what the column's pattern demands.
    assert len(projection["content_lineage_hmac"]) == 64
    assert all(c in "0123456789abcdef" for c in projection["content_lineage_hmac"])
    assert projection["normalized_payload"] == {
        "schema_version": "calendar-v03",
        "record_kind": "calendar_classification",
        "classification_state": "candidate",
        "artifact_type": "travel_itinerary",
    }


def test_the_title_never_leaves(lambda_module):
    """The property the whole design rests on.

    The classifier's own docstring: the private source title *participates only
    in the HMAC lineage and is not returned*. This asserts it of the projection
    that actually gets stored, since that is the thing a reviewer would find in
    the database.
    """
    title = "Dinner with Alexandra at Le Bernardin"
    _, projection = classify(lambda_module, {
        "title": title,
        "location": "155 W 51st St",
        "startsAt": "2026-09-02T19:00:00Z",
        "organizer": "alexandra@example.com",
    })
    flat = repr(projection)
    for secret in ("Alexandra", "Bernardin", "51st", "example.com"):
        assert secret not in flat


def test_an_ordinary_appointment_is_excluded(lambda_module):
    """Most rows, and the three-key payload the constraint wants for them."""
    _, projection = classify(lambda_module, {
        "title": "Outpatient",
        "startsAt": "2026-04-02T09:00:00Z",
    })
    assert projection["classification_state"] == "excluded"
    assert projection["normalized_payload"] == {
        "schema_version": "calendar-v03",
        "record_kind": "calendar_classification",
        "classification_state": "excluded",
    }
    assert "artifact_type" not in projection["normalized_payload"]


def test_a_holiday_feed_cannot_look_like_a_ticket(lambda_module):
    """Container provenance beats title interpretation.

    49 of 77 events on a real device were public holidays. A subscribed feed
    must not get in by being named like a booking.
    """
    _, projection = classify(lambda_module, {
        "title": "Ticket: Karneval",
        "startsAt": "2026-02-16T00:00:00Z",
        "isAllDay": True,
        "calendarType": "subscription",
        "calendarName": "US Holidays",
    }, calendar={"calendar_name": "US Holidays", "calendar_type": "subscription",
                 "subscribed": True})
    assert projection["classification_state"] == "excluded"


def test_a_cancelled_event_is_excluded(lambda_module):
    _, projection = classify(lambda_module, dict(FLIGHT, isCancelled=True))
    assert projection["classification_state"] == "excluded"


def test_the_flags_survive_the_join(lambda_module):
    """`isCancelled` is only honoured if `_extra` wrote `cancelled=1`.

    The negative half of the test above: without the flag mapping, a cancelled
    flight would classify as a live candidate. Asserting the extra string
    directly is what distinguishes "excluded because cancelled" from "excluded
    for some other reason", which the disposition alone would hide.
    """
    row = lambda_module.legacy_row(
        dict(FLIGHT, isCancelled=True, isAllDay=False, durationMinutes=155.0),
        "event-1",
    )

    extra = dict(pair.split("=", 1) for pair in row["extra"].split(";") if pair)
    assert extra["cancelled"] == "1"
    assert extra["booked"] == "1"
    assert extra["start"] == "2026-11-14T18:30:00Z"
    assert extra["cal_type"] == "caldav"
    # `isAllDay` is false, so the key is absent rather than `all_day=0` — the
    # classifier tests for presence and a stated blank is not an absence.
    assert "all_day" not in extra


def test_snake_case_would_classify_everything_as_unknown(lambda_module):
    """Proof the casing is load-bearing rather than incidental.

    This is what the HealthKit adapter's first draft did. Every field reads as
    absent, so a real booked flight becomes an ordinary excluded row — a failure
    that looks exactly like a private calendar being correctly protected.
    """
    _, projection = classify(lambda_module, {
        "title": FLIGHT["title"],
        "starts_at": "2026-11-14T18:30:00Z",
        "is_booked": True,
    })
    assert projection["classification_state"] != "candidate"


def test_lineage_is_salted_per_user(lambda_module):
    """Two people with the same flight must not share a lineage hmac.

    `content_lineage_hmac` is a column that exists to be joined on, so an
    unsalted digest would be a cross-account correlation handle. Same reasoning
    as `sourceItemHmac`.
    """
    row = lambda_module.legacy_row(dict(FLIGHT), "event-1")
    first = lambda_module.classifier_for("user-1").classify(row)
    second = lambda_module.classifier_for("user-2").classify(row)
    assert first.included and second.included
    assert lambda_module.project(first)["content_lineage_hmac"] != \
        lambda_module.project(second)["content_lineage_hmac"]
