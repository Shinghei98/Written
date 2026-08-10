from __future__ import annotations

import hashlib
import hmac
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone

from written_ontology.calendar_semantics import (
    CalendarClassifier,
    CalendarDisposition,
    Surface,
    build_journeys,
    deduplicate_flight_segments,
    derive_travel_candidates,
    surface_wording_license,
)


TEST_LINEAGE_KEY = b"calendar-semantics-test-key-only"


def utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


class CalendarSemanticsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.classifier = CalendarClassifier(
            place_catalog={
                "AAA": "place:a",
                "Alpha City": "place:a",
                "HHH": "place:hub",
                "Hub City": "place:hub",
                "BBB": "place:b",
                "Beta City": "place:b",
                "CCC": "place:c",
                "Gamma City": "place:c",
            },
            place_labels={
                "place:a": "Alpha City",
                "place:hub": "Hub City",
                "place:b": "Beta City",
                "place:c": "Gamma City",
            },
            carrier_codes={"XY", "ZZ"},
            recognized_leisure_vendors={
                "Eventbrite",
                "Example Tours",
                "Leisure Vendor",
                "OpenTable",
                "Resy",
                "Ticketmaster",
            },
            lineage_key=TEST_LINEAGE_KEY,
        )

    @staticmethod
    def flight_row(
        *,
        source: str,
        item_id: str,
        origin_code: str,
        destination_code: str,
        destination_label: str,
        flight_number: int,
        starts_at: str,
        ends_at: str,
        reservation_id: str | None,
    ) -> dict[str, object]:
        extra: dict[str, str] = {
            "origin_code": origin_code,
            "destination_code": destination_code,
            "start": starts_at,
            "end": ends_at,
            "duration_min": str(
                int((utc(ends_at) - utc(starts_at)).total_seconds() // 60)
            ),
        }
        if reservation_id:
            extra["reservation_id"] = reservation_id
        return {
            "source": source,
            "data_type": "event",
            "item_id": item_id,
            "name": f"FLIGHT to {destination_label} (XY {flight_number})",
            "detail": f"{destination_label} {destination_code}",
            "creator": "Synthetic itinerary provider",
            "extra": extra,
        }

    def segment(self, **kwargs: object):
        decision = self.classifier.classify(self.flight_row(**kwargs))
        self.assertEqual(decision.disposition, CalendarDisposition.FLIGHT_SEGMENT)
        self.assertIsNotNone(decision.flight_segment)
        return decision.flight_segment

    def four_leg_round_trip_rows(self) -> list[dict[str, object]]:
        legs = [
            dict(
                origin_code="AAA",
                destination_code="HHH",
                destination_label="Hub City",
                flight_number=101,
                starts_at="2030-01-01T08:00:00Z",
                ends_at="2030-01-01T10:00:00Z",
                reservation_id="OUTBOUND",
            ),
            dict(
                origin_code="HHH",
                destination_code="BBB",
                destination_label="Beta City",
                flight_number=102,
                starts_at="2030-01-01T12:00:00Z",
                ends_at="2030-01-01T16:00:00Z",
                reservation_id="OUTBOUND",
            ),
            dict(
                origin_code="BBB",
                destination_code="HHH",
                destination_label="Hub City",
                flight_number=201,
                starts_at="2030-02-15T08:00:00Z",
                ends_at="2030-02-15T12:00:00Z",
                reservation_id="RETURN",
            ),
            dict(
                origin_code="HHH",
                destination_code="AAA",
                destination_label="Alpha City",
                flight_number=202,
                starts_at="2030-02-15T14:00:00Z",
                ends_at="2030-02-15T16:00:00Z",
                reservation_id="RETURN",
            ),
        ]
        rows: list[dict[str, object]] = []
        for index, leg in enumerate(legs):
            rows.append(
                self.flight_row(
                    source="apple_calendar",
                    item_id=f"apple-{index}",
                    **leg,
                )
            )
            rows.append(
                self.flight_row(
                    source="google_calendar",
                    item_id=f"google-{index}",
                    **leg,
                )
            )
        return rows

    def test_one_strong_ticket_is_sufficient_without_cross_source_proof(self) -> None:
        segment = self.segment(
            source="apple_calendar",
            item_id="one-ticket",
            origin_code="AAA",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=10,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T12:00:00Z",
            reservation_id=None,
        )
        journeys = self.classifier.build_journeys([segment])
        candidates = self.classifier.travel_candidates(journeys)
        scheduled = next(item for item in candidates if item.predicate == "scheduled_travel_to")
        self.assertEqual(scheduled.journey_votes, 1)
        self.assertGreaterEqual(scheduled.evidence_confidence, 0.90)
        self.assertEqual(segment.connector_sources, ("apple_calendar",))

    def test_subscribed_calendar_alias_precedes_ticket_and_flight_parsing(self) -> None:
        flight_like = self.flight_row(
            source="apple_calendar",
            item_id="subscribed-flight-like",
            origin_code="AAA",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=10,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T12:00:00Z",
            reservation_id="BOOKED",
        )
        flight_like["extra"]["cal_type"] = "subscription"
        decision = self.classifier.classify(flight_like)
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_CALENDAR)
        self.assertIsNone(decision.flight_segment)

        ticket_like = {
            "source": "google_calendar",
            "data_type": "event",
            "item_id": "subscribed-ticket-like",
            "name": "Ticketmaster concert ticket",
            "creator": "Ticketmaster",
            "detail": "",
            "extra": {
                "cal_type": "holiday",
                "booked": "1",
                "url": "https://ticketmaster.invalid/event/1",
                "start": "2030-02-01T19:00:00Z",
            },
        }
        decision = self.classifier.classify(ticket_like)
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_CALENDAR)
        self.assertIsNone(decision.booked_activity)

    def test_duplicate_four_leg_round_trip_and_transit_zero(self) -> None:
        segments = []
        for row in self.four_leg_round_trip_rows():
            decision = self.classifier.classify(row)
            self.assertEqual(decision.disposition, CalendarDisposition.FLIGHT_SEGMENT)
            segments.append(decision.flight_segment)

        deduplicated = deduplicate_flight_segments(segments)
        self.assertEqual(len(deduplicated), 4)
        self.assertTrue(all(len(item.connector_sources) == 2 for item in deduplicated))

        journeys = self.classifier.build_journeys(deduplicated)
        self.assertEqual(len(journeys), 2)
        self.assertEqual(journeys[0].terminal_place_id, "place:b")
        self.assertEqual(journeys[0].transit_place_ids, ("place:hub",))
        self.assertEqual(journeys[1].terminal_place_id, "place:a")
        self.assertEqual(journeys[1].transit_place_ids, ("place:hub",))
        self.assertIsNotNone(journeys[0].round_trip_group_id)
        self.assertEqual(
            journeys[0].round_trip_group_id,
            journeys[1].round_trip_group_id,
        )

        candidates = self.classifier.travel_candidates(journeys)
        self.assertNotIn("place:hub", {item.place_id for item in candidates})
        self.assertEqual(
            {item.place_id for item in candidates if item.predicate == "scheduled_travel_to"},
            {"place:a", "place:b"},
        )

    def test_one_round_trip_is_not_recurrence_or_hometown(self) -> None:
        segments = [
            self.classifier.classify(row).flight_segment
            for row in self.four_leg_round_trip_rows()
        ]
        candidates = self.classifier.travel_candidates(
            self.classifier.build_journeys(segments)
        )
        predicates = {item.predicate for item in candidates}
        self.assertEqual(predicates, {"scheduled_travel_to"})
        self.assertTrue(
            {"visited", "likes", "hometown", "lives_in"}.isdisjoint(predicates)
        )
        self.assertTrue(all(item.recurrence_score == 0.0 for item in candidates))

    def test_recurrence_and_possible_base_remain_private_review_candidates(self) -> None:
        first = [
            self.classifier.classify(row).flight_segment
            for row in self.four_leg_round_trip_rows()
        ]
        second_rows: list[dict[str, object]] = []
        for row in self.four_leg_round_trip_rows():
            shifted = dict(row)
            shifted_extra = dict(row["extra"])
            for key in ("start", "end"):
                shifted_extra[key] = (
                    utc(str(shifted_extra[key])) + timedelta(days=200)
                ).isoformat()
            shifted["extra"] = shifted_extra
            shifted["item_id"] = f"second-{row['item_id']}"
            second_rows.append(shifted)
        second = [
            self.classifier.classify(row).flight_segment for row in second_rows
        ]
        candidates = self.classifier.travel_candidates(
            self.classifier.build_journeys([*first, *second])
        )
        predicates = {item.predicate for item in candidates}
        self.assertIn("recurring_travel_connection_for_review", predicates)
        self.assertIn("possible_base_for_review", predicates)
        self.assertNotIn("hometown", predicates)
        self.assertTrue(all(item.memories_only for item in candidates))

    def test_public_often_travels_requires_three_journeys_and_two_round_trips(self) -> None:
        all_segments = []
        for episode, offset_days in enumerate((0, 200, 400)):
            for row in self.four_leg_round_trip_rows():
                shifted = dict(row)
                shifted_extra = dict(row["extra"])
                for key in ("start", "end"):
                    shifted_extra[key] = (
                        utc(str(shifted_extra[key])) + timedelta(days=offset_days)
                    ).isoformat()
                shifted["extra"] = shifted_extra
                shifted["item_id"] = f"episode-{episode}-{row['item_id']}"
                all_segments.append(self.classifier.classify(shifted).flight_segment)

        candidates = self.classifier.travel_candidates(
            self.classifier.build_journeys(all_segments)
        )
        recurring = next(
            item
            for item in candidates
            if item.predicate == "recurring_travel_connection_for_review"
            and item.place_id == "place:b"
        )
        self.assertEqual(recurring.journey_votes, 3)
        self.assertEqual(recurring.complete_round_trip_count, 3)
        allowed = surface_wording_license(
            recurring,
            Surface.PUBLIC_BIO,
            confirmed_predicate="often_travels_to",
            explicit_confirmation=True,
            surface_permission=True,
        )
        self.assertTrue(allowed.allowed)

        weakened = replace(recurring, complete_round_trip_count=1)
        denied = surface_wording_license(
            weakened,
            Surface.PUBLIC_BIO,
            confirmed_predicate="often_travels_to",
            explicit_confirmation=True,
            surface_permission=True,
        )
        self.assertFalse(denied.allowed)
        self.assertIn("two_round_trips", denied.reason)

    def test_ambiguous_tp_destination_abstains(self) -> None:
        classifier = CalendarClassifier(
            place_catalog={"TP": ("place:one", "place:two")},
            carrier_codes={"XY"},
            lineage_key=TEST_LINEAGE_KEY,
        )
        decision = classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "ambiguous",
                "name": "FLIGHT to TP (XY 123)",
                "detail": "TP",
                "extra": {
                    "start": "2030-01-01T08:00:00Z",
                    "end": "2030-01-01T10:00:00Z",
                    "duration_min": "120",
                },
            }
        )
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_UNKNOWN)
        self.assertEqual(decision.reason, "ambiguous_or_unknown_destination")

    def test_generic_flight_abstains(self) -> None:
        decision = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "generic-flight",
                "name": "Flight",
                "extra": {
                    "start": "2030-01-01T08:00:00Z",
                    "end": "2030-01-01T09:00:00Z",
                },
            }
        )
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_UNKNOWN)
        self.assertEqual(decision.reason, "generic_or_malformed_flight_title")

    def test_tour_is_booked_activity_not_visited(self) -> None:
        decision = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "tour",
                "name": "Ticket: Old Town food tour",
                "creator": "Example Tours",
                "detail": "Beta City BBB",
                "extra": {
                    "booked": "1",
                    "url": "https://tickets.invalid/synthetic",
                    "start": "2030-04-01T10:00:00Z",
                    "end": "2030-04-01T12:00:00Z",
                },
            }
        )
        self.assertEqual(decision.disposition, CalendarDisposition.BOOKED_ACTIVITY)
        activity = decision.booked_activity
        self.assertEqual(activity.predicate, "booked_activity_at")
        self.assertEqual(activity.activity_label, "Food tour")
        self.assertFalse(hasattr(activity, "visited"))
        license_ = surface_wording_license(
            activity,
            Surface.MEMORIES,
            now=utc("2030-01-01T00:00:00Z"),
        )
        self.assertTrue(license_.allowed)
        self.assertNotIn("visited", license_.wording.casefold())
        self.assertNotIn("old town", license_.wording.casefold())

    def test_live_event_and_dining_are_typed_scheduled_actions(self) -> None:
        live = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "live-ticket",
                "name": "Ticket: Synthetic Artist concert",
                "creator": "Leisure Vendor",
                "extra": {
                    "url": "https://tickets.invalid/synthetic-live",
                    "start": "2030-05-01T19:00:00Z",
                },
            }
        )
        dining = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "dining-booking",
                "name": "Reservation at Synthetic Restaurant",
                "creator": "Leisure Vendor",
                "extra": {
                    "url": "https://bookings.invalid/synthetic-dining",
                    "start": "2030-05-02T19:00:00Z",
                },
            }
        )
        self.assertEqual(live.disposition, CalendarDisposition.BOOKED_ACTIVITY)
        self.assertEqual(live.booked_activity.predicate, "booked_event")
        self.assertEqual(live.booked_activity.activity_label, "Concert")
        self.assertEqual(dining.disposition, CalendarDisposition.BOOKED_ACTIVITY)
        self.assertEqual(dining.booked_activity.predicate, "scheduled_dining")
        self.assertEqual(
            dining.booked_activity.activity_label,
            "Restaurant reservation",
        )
        live_wording = surface_wording_license(
            live.booked_activity,
            Surface.MEMORIES,
            now=utc("2030-01-01T00:00:00Z"),
        )
        dining_wording = surface_wording_license(
            dining.booked_activity,
            Surface.MEMORIES,
            now=utc("2030-01-01T00:00:00Z"),
        )
        self.assertNotIn("synthetic artist", live_wording.wording.casefold())
        self.assertNotIn("synthetic restaurant", dining_wording.wording.casefold())

    def test_ticket_and_restaurant_vendors_type_generic_receipts(self) -> None:
        event = self.classifier.classify(
            {
                "source": "google_calendar",
                "data_type": "event",
                "item_id": "generic-event-receipt",
                "name": "Synthetic admission pass",
                "creator": "Ticketmaster",
                "extra": {
                    "url": "https://tickets.invalid/synthetic-event",
                    "start": "2030-06-01T19:00:00Z",
                },
            }
        )
        dining = self.classifier.classify(
            {
                "source": "google_calendar",
                "data_type": "event",
                "item_id": "generic-dining-receipt",
                "name": "Synthetic booking",
                "creator": "OpenTable",
                "extra": {
                    "url": "https://bookings.invalid/synthetic-dining",
                    "start": "2030-06-02T19:00:00Z",
                },
            }
        )
        self.assertEqual(event.disposition, CalendarDisposition.BOOKED_ACTIVITY)
        self.assertEqual(event.booked_activity.predicate, "booked_event")
        self.assertEqual(event.booked_activity.activity_label, "Ticketed event")
        self.assertEqual(dining.disposition, CalendarDisposition.BOOKED_ACTIVITY)
        self.assertEqual(dining.booked_activity.predicate, "scheduled_dining")

        substring_false_positive = self.classifier.classify(
            {
                "source": "google_calendar",
                "data_type": "event",
                "item_id": "unrelated-host",
                "name": "Synthetic opaque block",
                "extra": {
                    "url": "https://heresy.example/reservation",
                    "start": "2030-06-03T19:00:00Z",
                },
            }
        )
        self.assertEqual(
            substring_false_positive.disposition,
            CalendarDisposition.EXCLUDED_UNKNOWN,
        )
        forged_subdomain = {
            "source": "google_calendar",
            "data_type": "event",
            "item_id": "forged-vendor-host",
            "name": "Synthetic opaque block",
            "extra": {
                "url": "https://resy.evil.example/reservation",
                "start": "2030-06-03T20:00:00Z",
            },
        }
        self.assertEqual(
            self.classifier.classify(forged_subdomain).disposition,
            CalendarDisposition.EXCLUDED_UNKNOWN,
        )

    def test_explicit_negative_owner_blocks_strong_tour_without_artifact(self) -> None:
        base = {
            "source": "apple_calendar",
            "data_type": "event",
            "item_id": "third-party-tour",
            "name": "Ticket: Old Town food tour",
            "creator": "Example Tours",
            "detail": "Beta City BBB",
            "extra": {
                "booked": "1",
                "url": "https://tickets.invalid/synthetic",
                "owner_is_user": "0",
                "start": "2030-04-01T10:00:00Z",
                "end": "2030-04-01T12:00:00Z",
            },
        }
        blocked = self.classifier.classify(base)
        self.assertEqual(blocked.disposition, CalendarDisposition.EXCLUDED_OWNERSHIP)
        override = dict(base)
        override["extra"] = {
            **base["extra"],
            "user_owned_booking_artifact": "1",
        }
        allowed = self.classifier.classify(override)
        self.assertEqual(allowed.disposition, CalendarDisposition.BOOKED_ACTIVITY)

    def test_booked_intermediate_activity_turns_connection_into_stopover(self) -> None:
        first = self.segment(
            source="apple_calendar",
            item_id="stopover-flight-1",
            origin_code="AAA",
            destination_code="HHH",
            destination_label="Hub City",
            flight_number=31,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T10:00:00Z",
            reservation_id="ONE-ITINERARY",
        )
        second = self.segment(
            source="apple_calendar",
            item_id="stopover-flight-2",
            origin_code="HHH",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=32,
            starts_at="2030-01-01T15:00:00Z",
            ends_at="2030-01-01T19:00:00Z",
            reservation_id="ONE-ITINERARY",
        )
        activity_decision = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "hub-activity",
                "name": "Ticket: Hub City walking tour",
                "creator": "Example Tours",
                "detail": "Hub City HHH",
                "extra": {
                    "booked": "1",
                    "url": "https://tickets.invalid/synthetic",
                    "start": "2030-01-01T11:00:00Z",
                    "end": "2030-01-01T13:00:00Z",
                },
            }
        )
        self.assertEqual(
            activity_decision.disposition, CalendarDisposition.BOOKED_ACTIVITY
        )
        no_activity = self.classifier.build_journeys([first, second])
        with_activity = self.classifier.build_journeys(
            [first, second], booked_activities=[activity_decision.booked_activity]
        )
        self.assertEqual(len(no_activity), 1)
        self.assertEqual(len(with_activity), 2)
        self.assertEqual(with_activity[0].terminal_place_id, "place:hub")

    def test_booked_work_meeting_is_excluded_before_vendor_or_ticket(self) -> None:
        decision = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "work-ticket",
                "name": "Ticket: Research meeting at the museum",
                "creator": "Leisure Vendor",
                "extra": {"booked": "1", "url": "https://tickets.invalid/synthetic"},
            }
        )
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_WORK)

    def test_booked_flag_alone_is_never_sufficient(self) -> None:
        decision = self.classifier.classify(
            {
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": "opaque-booking",
                "name": "Private item",
                "extra": {"booked": "1"},
            }
        )
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_UNKNOWN)

    def test_private_categories_and_unknown_fail_closed(self) -> None:
        cases = {
            "Alex's birthday": CalendarDisposition.EXCLUDED_PERSONAL,
            "Alex's concert": CalendarDisposition.EXCLUDED_PERSONAL,
            "Medical clinic appointment": CalendarDisposition.EXCLUDED_SENSITIVE,
            "Jordan's funeral": CalendarDisposition.EXCLUDED_PERSONAL,
            "Taylor's arrival": CalendarDisposition.EXCLUDED_PERSONAL,
            "Zoom lab meeting": CalendarDisposition.EXCLUDED_WORK,
            "Opaque personal block": CalendarDisposition.EXCLUDED_UNKNOWN,
        }
        for index, (title, expected) in enumerate(cases.items()):
            with self.subTest(title=title):
                decision = self.classifier.classify(
                    {
                        "source": "apple_calendar",
                        "data_type": "event",
                        "item_id": f"private-{index}",
                        "name": title,
                        "extra": {},
                    }
                )
                self.assertEqual(decision.disposition, expected)

    def test_medical_shorthand_cannot_mimic_ticket_or_tour(self) -> None:
        for index, title in enumerate(
            (
                "Ticket: MRI scan tour",
                "Museum meeting after blood test",
                "Hotel near physical therapy",
                "CT scan appointment",
            )
        ):
            with self.subTest(title=title):
                decision = self.classifier.classify(
                    {
                        "source": "apple_calendar",
                        "data_type": "event",
                        "item_id": f"medical-shorthand-{index}",
                        "name": title,
                        "creator": "Example Tours",
                        "extra": {
                            "booked": "1",
                            "url": "https://tickets.invalid/synthetic",
                        },
                    }
                )
                self.assertEqual(
                    decision.disposition, CalendarDisposition.EXCLUDED_SENSITIVE
                )

    def test_subscribed_birthday_and_holiday_calendars_are_excluded(self) -> None:
        valid_flight = self.flight_row(
            source="apple_calendar",
            item_id="calendar-exclusion",
            origin_code="AAA",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=11,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T12:00:00Z",
            reservation_id=None,
        )
        metadata_cases = (
            {"name": "Birthdays", "extra": {"type": "birthday"}},
            {"name": "Public feed", "extra": {"type": "subscription", "subscribed": "1"}},
            {"name": "Regional Holidays", "extra": {"type": "caldav"}},
        )
        for metadata in metadata_cases:
            with self.subTest(metadata=metadata):
                decision = self.classifier.classify(
                    valid_flight, calendar_metadata=metadata
                )
                self.assertEqual(
                    decision.disposition, CalendarDisposition.EXCLUDED_CALENDAR
                )

    def test_future_unconfirmed_flight_is_memories_only(self) -> None:
        segment = self.segment(
            source="apple_calendar",
            item_id="future",
            origin_code="AAA",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=12,
            starts_at="2035-01-01T08:00:00Z",
            ends_at="2035-01-01T12:00:00Z",
            reservation_id=None,
        )
        memory = surface_wording_license(
            segment, Surface.MEMORIES, now=utc("2030-01-01T00:00:00Z")
        )
        public = surface_wording_license(
            segment, Surface.PUBLIC_BIO, now=utc("2030-01-01T00:00:00Z")
        )
        false_visit = surface_wording_license(
            segment,
            Surface.PUBLIC_BIO,
            now=utc("2030-01-01T00:00:00Z"),
            confirmed_predicate="visited",
            explicit_confirmation=True,
            surface_permission=True,
        )
        self.assertTrue(memory.allowed)
        self.assertEqual(memory.predicate, "scheduled_travel_to")
        self.assertFalse(public.allowed)
        self.assertFalse(false_visit.allowed)

    def test_one_journey_contributes_at_most_one_terminal_vote(self) -> None:
        rows = self.four_leg_round_trip_rows()[:4]
        segments = [self.classifier.classify(row).flight_segment for row in rows]
        journeys = self.classifier.build_journeys(segments)
        self.assertEqual(len(journeys), 1)
        candidates = self.classifier.travel_candidates(journeys)
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0].place_id, "place:b")
        self.assertEqual(candidates[0].journey_votes, 1)

    def test_removed_valid_flight_is_excluded_before_parsing(self) -> None:
        row = self.flight_row(
            source="apple_calendar",
            item_id="removed-flight",
            origin_code="AAA",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=13,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T12:00:00Z",
            reservation_id=None,
        )
        row["extra"] = {**row["extra"], "removed_by_user": ""}
        decision = self.classifier.classify(row)
        self.assertEqual(decision.disposition, CalendarDisposition.EXCLUDED_REMOVED)

    def test_connection_window_requires_reservation_after_eighteen_hours(self) -> None:
        first = self.segment(
            source="apple_calendar",
            item_id="long-connect-1",
            origin_code="AAA",
            destination_code="HHH",
            destination_label="Hub City",
            flight_number=20,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T10:00:00Z",
            reservation_id="SAME",
        )
        same_reservation = self.segment(
            source="apple_calendar",
            item_id="long-connect-2",
            origin_code="HHH",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=21,
            starts_at="2030-01-02T06:00:00Z",
            ends_at="2030-01-02T10:00:00Z",
            reservation_id="SAME",
        )
        different_reservation = self.segment(
            source="apple_calendar",
            item_id="long-connect-3",
            origin_code="HHH",
            destination_code="CCC",
            destination_label="Gamma City",
            flight_number=22,
            starts_at="2030-01-02T06:00:00Z",
            ends_at="2030-01-02T10:00:00Z",
            reservation_id="OTHER",
        )
        same = build_journeys(
            [first, same_reservation], lineage_key=TEST_LINEAGE_KEY
        )
        different = build_journeys(
            [first, different_reservation], lineage_key=TEST_LINEAGE_KEY
        )
        self.assertEqual(len(same), 1)
        self.assertEqual(len(different), 2)

    def test_lineage_is_keyed_hmac_not_plain_hash(self) -> None:
        segment = self.segment(
            source="apple_calendar",
            item_id="hmac",
            origin_code="AAA",
            destination_code="BBB",
            destination_label="Beta City",
            flight_number=30,
            starts_at="2030-01-01T08:00:00Z",
            ends_at="2030-01-01T12:00:00Z",
            reservation_id=None,
        )
        payload = "\x1f".join(
            (
                "flight_segment",
                "XY",
                "30",
                utc("2030-01-01T08:00:00Z").isoformat(),
                "place:b",
            )
        ).encode()
        expected = hmac.new(TEST_LINEAGE_KEY, payload, hashlib.sha256).hexdigest()
        plain = hashlib.sha256(payload).hexdigest()
        self.assertEqual(segment.lineage_id, expected)
        self.assertNotEqual(segment.lineage_id, plain)


if __name__ == "__main__":
    unittest.main()
