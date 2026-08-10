from __future__ import annotations

import csv
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from written_ontology.calendar_semantics import CalendarClassifier
from written_ontology.export_adapter import AdapterCapabilities, WrittenExportAdapter
from written_ontology.graph import OntologyGraph
from written_ontology.mapping import (
    DEFAULT_SOURCE_QUALITY,
    ObservationMapper,
    SOURCE_ACTION_PAIRS,
)
from written_ontology.models import Concept, InferencePolicyName


FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_written_export.csv"
FIELDS = (
    "source",
    "data_type",
    "item_id",
    "name",
    "creator",
    "detail",
    "extra",
    "collected_at",
)


def row(
    source: str,
    data_type: str,
    item_id: str = "",
    name: str = "",
    creator: str = "",
    detail: str = "",
    extra: str = "",
) -> dict[str, str]:
    return {
        "source": source,
        "data_type": data_type,
        "item_id": item_id,
        "name": name,
        "creator": creator,
        "detail": detail,
        "extra": extra,
        "collected_at": "2030-01-15T03:18:10Z",
    }


def trusted_fixture_catalog_identity(
    csv_row: dict[str, str],
    extra: dict[str, str],
) -> tuple[str, str, str] | None:
    """Test stand-in for a server-side signed catalog provenance verifier."""
    if extra.get("catalog_verified") != "1":
        return None
    resource_type = extra.get("catalog_resource_type") or extra.get("resource_type")
    catalog_id = extra.get("provider_catalog_id") or extra.get("catalog_id") or csv_row["item_id"]
    if not resource_type or not catalog_id:
        return None
    return csv_row["source"], resource_type, catalog_id


class ExportAdapterTests(unittest.TestCase):
    def read_rows(
        self,
        rows: list[dict[str, str]],
        *,
        capabilities: AdapterCapabilities | None = None,
        youtube_channel_resolver: object | None = None,
        calendar_classifier: CalendarClassifier | None = None,
    ) -> object:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "export.csv"
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=FIELDS)
                writer.writeheader()
                writer.writerows(rows)
            return WrittenExportAdapter(
                catalog_identity_verifier=trusted_fixture_catalog_identity,
                capabilities=capabilities,
                youtube_channel_resolver=youtube_channel_resolver,
                calendar_classifier=calendar_classifier,
            ).read(path)

    def test_source_specific_gates(self) -> None:
        result = WrittenExportAdapter().read(FIXTURE)
        self.assertEqual(len(result.observations), 5)
        self.assertEqual(result.excluded_counts["non_choice_recommendation"], 1)
        self.assertEqual(result.excluded_counts["sensitive_calendar_event"], 1)
        self.assertEqual(result.excluded_counts["calendar_event_not_allowlisted"], 1)
        self.assertEqual(result.excluded_counts["user_removed_observation"], 1)
        self.assertEqual(result.routed_profile_counts["user|education"], 1)
        self.assertEqual(result.routed_location_counts["location|place"], 1)
        self.assertEqual(
            result.routed_connection_counts["user|apple_music_subscription"], 1
        )
        self.assertEqual(result.policy_quarantined_counts, {})
        self.assertEqual(len(result.fitness_records), 3)
        self.assertEqual(result.fitness_coverage.state.value, "mixed")
        self.assertEqual(result.fitness_habit_candidates, ())
        self.assertTrue(
            all(
                (item.data_type, item.action) in SOURCE_ACTION_PAIRS[item.source]
                for item in result.observations
            )
        )

    def test_music_duplicates_share_lineage_but_calendar_is_private(self) -> None:
        result = WrittenExportAdapter().read(FIXTURE)
        music = [item for item in result.observations if item.independence_group == "music"]
        calendar = [item for item in result.observations if item.independence_group == "calendar"]
        self.assertEqual(len({item.content_lineage for item in music}), 1)
        self.assertEqual({item.independence_group for item in music}, {"music"})
        self.assertEqual(len(calendar), 1)
        self.assertEqual(calendar[0].privacy_class, "private_calendar_sanitized")
        self.assertFalse(calendar[0].allow_external_resolution)
        self.assertTrue(all(not term.safe_for_online for term in calendar[0].terms))
        self.assertEqual(
            {term.text for term in calendar[0].terms},
            {"Food tour", "New York"},
        )
        self.assertEqual(calendar[0].metadata["predicate"], "booked_activity_at")

    def test_calendar_booking_subtype_reaches_sanitized_metadata(self) -> None:
        classifier = CalendarClassifier(
            place_catalog={},
            carrier_codes={"XY"},
            recognized_leisure_vendors={"Leisure Vendor"},
            lineage_key=b"synthetic-export-booking-subtype-key",
        )
        result = self.read_rows(
            [
                row(
                    "apple_calendar",
                    "event",
                    "synthetic-live-ticket",
                    "Ticket: Synthetic Artist concert",
                    creator="Leisure Vendor",
                    extra=(
                        "url=https://tickets.invalid/synthetic-live;"
                        "start=2030-05-01T19:00:00Z"
                    ),
                )
            ],
            calendar_classifier=classifier,
        )
        self.assertEqual(len(result.observations), 1)
        observation = result.observations[0]
        self.assertEqual(observation.metadata["predicate"], "booked_event")
        self.assertEqual(observation.metadata["activity_category"], "Concert")
        self.assertEqual({term.text for term in observation.terms}, {"Concert"})
        self.assertNotIn("Synthetic Artist", repr(observation))
        self.assertEqual(observation.action_weight, 0.90)
        self.assertEqual(observation.field_quality, 0.92)
        self.assertAlmostEqual(
            observation.action_weight
            * observation.field_quality
            * DEFAULT_SOURCE_QUALITY[observation.source],
            0.7452,
        )

    def test_mirrored_calendar_events_share_one_private_lineage(self) -> None:
        classifier = CalendarClassifier(
            place_catalog={
                "AAA": "place:alpha",
                "Alpha City": "place:alpha",
                "BBB": "place:beta",
                "Beta City": "place:beta",
            },
            place_labels={
                "place:alpha": "Alpha City",
                "place:beta": "Beta City",
            },
            carrier_codes={"XY"},
            lineage_key=b"synthetic-export-adapter-test-key",
        )
        rows = [
            row(
                "apple_calendar", "event", "apple-id", "FLIGHT to Beta City (XY 123)",
                detail="Alpha City AAA",
                extra=(
                    "start=2030-01-03T18:00:00Z;end=2030-01-03T20:00:00Z;"
                    "duration_min=120"
                ),
            ),
            row(
                "google_calendar", "event", "google-id", "FLIGHT to Beta City (XY 123)",
                detail="Alpha City AAA",
                extra=(
                    "start=2030-01-03T18:00:00Z;end=2030-01-03T20:00:00Z;"
                    "duration_min=120"
                ),
            ),
        ]
        result = self.read_rows(rows, calendar_classifier=classifier)
        self.assertEqual(len(result.observations), 2)
        self.assertEqual(
            len({item.content_lineage for item in result.observations}),
            1,
        )
        self.assertEqual(
            {item.independence_group for item in result.observations},
            {"calendar"},
        )
        self.assertTrue(
            all(item.metadata["predicate"] == "scheduled_travel_to" for item in result.observations)
        )
        self.assertTrue(
            all({term.text for term in item.terms} == {"Beta City"} for item in result.observations)
        )
        self.assertTrue(all(item.action_weight == 0.92 for item in result.observations))
        self.assertTrue(all(item.field_quality == 0.95 for item in result.observations))
        self.assertTrue(
            all(
                abs(
                    item.action_weight
                    * item.field_quality
                    * DEFAULT_SOURCE_QUALITY[item.source]
                    - 0.7866
                )
                < 1e-12
                for item in result.observations
            )
        )

    def test_legacy_flight_title_is_destination_and_detail_is_origin(self) -> None:
        result = self.read_rows(
            [
                row(
                    "apple_calendar",
                    "event",
                    "legacy-flight",
                    "FLIGHT to London (BA 123)",
                    detail="New York JFK",
                    extra=(
                        "start=2030-01-03T18:00:00Z;"
                        "end=2030-01-03T22:00:00Z;duration_min=240"
                    ),
                )
            ]
        )
        self.assertEqual(len(result.observations), 1)
        observation = result.observations[0]
        self.assertEqual({term.text for term in observation.terms}, {"London"})
        self.assertEqual(observation.metadata["origin_place_id"], "place:new_york")
        self.assertEqual(observation.metadata["destination_place_id"], "place:london")
        self.assertEqual(observation.metadata["predicate"], "scheduled_travel_to")
        serialized = repr(observation)
        self.assertNotIn("BA 123", serialized)
        self.assertNotIn("New York JFK", serialized)

    def test_calendar_ownership_and_declined_attendance_fail_closed(self) -> None:
        base_extra = (
            "start=2030-01-03T18:00:00Z;end=2030-01-03T22:00:00Z;"
            "duration_min=240"
        )
        result = self.read_rows(
            [
                row(
                    "apple_calendar", "event", "not-owner",
                    "FLIGHT to London (BA 123)", detail="New York JFK",
                    extra=f"{base_extra};owner_is_user=0",
                ),
                row(
                    "apple_calendar", "event", "declined",
                    "FLIGHT to London (BA 124)", detail="New York JFK",
                    extra=f"{base_extra};attendee_status=declined",
                ),
                row(
                    "apple_calendar", "event", "artifact-override",
                    "FLIGHT to London (BA 125)", detail="New York JFK",
                    extra=(
                        f"{base_extra};owner_is_user=0;"
                        "user_owned_booking_artifact=1"
                    ),
                ),
            ]
        )
        self.assertEqual(len(result.observations), 1)
        self.assertEqual(
            result.excluded_counts["calendar_event_ownership_not_established"], 2
        )
        self.assertEqual(result.observations[0].metadata["predicate"], "scheduled_travel_to")

    def test_shared_third_party_calendar_is_not_user_intent(self) -> None:
        result = self.read_rows(
            [
                row(
                    "apple_calendar", "calendar", "shared-calendar", "Shared Trips",
                    extra="type=caldav;shared_third_party=1",
                ),
                row(
                    "apple_calendar", "event", "shared-flight",
                    "FLIGHT to London (BA 123)", detail="New York JFK",
                    extra=(
                        "calendar=Shared Trips;start=2030-01-03T18:00:00Z;"
                        "end=2030-01-03T22:00:00Z;duration_min=240"
                    ),
                ),
            ]
        )
        self.assertEqual(result.observations, ())
        self.assertEqual(result.excluded_counts["calendar_container_metadata"], 1)
        self.assertEqual(
            result.excluded_counts["calendar_event_ownership_not_established"], 1
        )

    def test_arbitrary_private_calendar_events_never_become_terms(self) -> None:
        result = self.read_rows(
            [
                row("apple_calendar", "event", "birthday", "Alex's birthday"),
                row("apple_calendar", "event", "medical", "Medical clinic visit"),
                row("apple_calendar", "event", "funeral", "Jordan's funeral"),
                row("apple_calendar", "event", "friend", "Taylor's arrival"),
                row("apple_calendar", "event", "work", "Zoom lab meeting"),
                row("apple_calendar", "event", "unknown", "Opaque timed block"),
            ]
        )
        self.assertEqual(result.observations, ())
        self.assertEqual(result.excluded_counts["private_personal_calendar_event"], 3)
        self.assertEqual(result.excluded_counts["sensitive_calendar_event"], 1)
        self.assertEqual(result.excluded_counts["work_school_calendar_event"], 1)
        self.assertEqual(result.excluded_counts["calendar_event_not_allowlisted"], 1)

    def test_pipe_and_comma_provider_lists_become_distinct_terms(self) -> None:
        rows = [
            row(
                "youtube", "liked_video", "y1", "Ignored title", "Ignored channel",
                extra="topics=Food|Entertainment,Travel",
            ),
            row(
                "apple_music", "recently_played", "m1", "Synthetic song", "Artist",
                extra="genres=Cantopop/HK-Pop|Music|Pop",
            ),
        ]
        result = self.read_rows(rows)
        youtube = next(item for item in result.observations if item.source == "youtube")
        music = next(item for item in result.observations if item.source == "apple_music")
        self.assertEqual(
            {term.text for term in youtube.terms},
            {"Food", "Entertainment", "Travel"},
        )
        self.assertTrue(
            {"Cantopop/HK-Pop", "Music", "Pop"}.issubset(
                {term.text for term in music.terms}
            )
        )

    def test_profile_location_and_connection_routes_are_strictly_separate(self) -> None:
        rows = [
            row("user", "education", "education", "Synthetic degree", extra="entered_by_user=1"),
            row("user", "gender", "gender", "Synthetic", extra="entered_by_user=1"),
            row(
                "user", "apple_music_subscription", "subscription", "subscribed",
                extra="measured=1",
            ),
            row("location", "place", "place", "Synthetic City", extra="city=Synthetic City"),
            row("user", "unknown_profile_field", "unknown", "value", extra="entered_by_user=1"),
            row("user", "occupation", "occupation", "value", extra="entered_by_user=0"),
        ]
        result = self.read_rows(rows)
        self.assertEqual(sum(result.routed_profile_counts.values()), 2)
        self.assertEqual(sum(result.routed_connection_counts.values()), 1)
        self.assertEqual(sum(result.routed_location_counts.values()), 1)
        self.assertEqual(result.excluded_counts["unsupported_user_data_type"], 1)
        self.assertEqual(result.excluded_counts["profile_without_explicit_provenance"], 1)
        self.assertEqual(result.observations, ())

    def test_exact_duplicate_rows_are_idempotent(self) -> None:
        duplicated = row(
            "apple_music", "recently_played", "m1", "Synthetic song", "Artist",
            extra="genres=Pop;last_played=2030-01-01T12:00:00Z",
        )
        result = self.read_rows([duplicated, duplicated])
        self.assertEqual(len(result.observations), 1)
        self.assertEqual(result.excluded_counts["duplicate_record_fingerprint"], 1)

    def test_youtube_uses_provider_topics_not_titles_by_default(self) -> None:
        result = WrittenExportAdapter().read(FIXTURE)
        youtube = [item for item in result.observations if item.source == "youtube"][0]
        term_text = {term.text for term in youtube.terms}
        self.assertIn("Film", term_text)
        self.assertNotIn("Free-form title that is not used", term_text)
        self.assertNotIn("Example Channel", term_text)
        self.assertFalse(youtube.allow_external_resolution)
        self.assertTrue(all(not term.safe_for_global_mining for term in youtube.terms))

    def test_youtube_derived_fields_require_capability_and_stable_channel_id(self) -> None:
        adapter = WrittenExportAdapter(
            capabilities=AdapterCapabilities(
                youtube_channel_entity_mapping=True,
                youtube_title_term_derivation=True,
            )
        )
        result = adapter.read(FIXTURE)
        youtube = [item for item in result.observations if item.source == "youtube"][0]
        term_text = {term.text for term in youtube.terms}
        self.assertIn("Free-form title that is not used", term_text)
        # The legacy fixture lacks a stable channel ID. A title alone cannot
        # become a channel or creator identity.
        self.assertNotIn("Example Channel", term_text)
        self.assertTrue(all(not term.safe_for_online for term in youtube.terms))

        with_stable_id = self.read_rows(
            [
                row(
                    "youtube",
                    "liked_video",
                    "video-1",
                    "Video title",
                    "Stable Channel",
                    extra=(
                        "category=Film;"
                        "channel_id=UCaaaaaaaaaaaaaaaaaaaaaa"
                    ),
                )
            ],
            capabilities=AdapterCapabilities(youtube_channel_identity_terms=True),
        )
        self.assertIn("Stable Channel", {term.text for term in with_stable_id.observations[0].terms})

    def test_health_and_healthkit_are_ingested_outside_generic_mapper(self) -> None:
        result = WrittenExportAdapter().read(FIXTURE)
        self.assertFalse(
            any(item.source in {"health", "healthkit"} for item in result.observations)
        )
        self.assertEqual(result.policy_quarantined_counts, {})
        self.assertEqual(len(result.fitness_records), 3)
        self.assertEqual(result.fitness_coverage.activity_days, 1)
        self.assertEqual(result.fitness_coverage.activity_hours, 1)
        self.assertEqual(result.fitness_coverage.workouts, 1)
        self.assertEqual(
            result.excluded_counts["unsupported_healthkit_data_type"], 1
        )

    def test_manual_activity_concept_does_not_unblock_healthkit(self) -> None:
        running = Concept(
            key="activity:running",
            label="Running",
            kind="activity",
            sensitivity="ordinary",
            inference_policy=InferencePolicyName.INFERABLE,
        )
        graph = OntologyGraph(
            concepts={running.key: running},
            edges=(),
            aliases={"running": [(running.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph)
        result = WrittenExportAdapter().read(FIXTURE)
        self.assertFalse(
            any(
                mapper.accepted_evidence(item, mapper.map_observation(item))
                for item in result.observations
            )
        )

    def test_legacy_removal_reason_is_not_propagated(self) -> None:
        result = WrittenExportAdapter().read(FIXTURE)
        serialized_metadata = repr([item.metadata for item in result.observations])
        self.assertNotIn("legacy_reason", serialized_metadata)
        self.assertNotIn("removed_reason", serialized_metadata)

    def test_removal_marker_withholds_every_source_without_using_reason(self) -> None:
        rows = [
            row(
                "apple_music", "recently_played", "m1", "Song", "Artist",
                extra="genres=Rock;removed_by_user=1;removed_reason=inaccurate",
            ),
            row(
                "youtube", "watched", "y1", "Video", "Channel",
                extra="category=Film;removed_by_user=;removed_reason=private",
            ),
            row(
                "podcast", "played", "p1", creator="Show",
                extra="show=Show;categories=Science;removed_by_user=now",
            ),
            row(
                "healthkit", "workout", "h1", "Running",
                extra="activity_type=running;removed_by_user=now;removed_reason=irrelevant",
            ),
        ]
        result = self.read_rows(rows)
        self.assertEqual(result.observations, ())
        self.assertEqual(result.excluded_counts["user_removed_observation"], 4)
        self.assertNotIn("inaccurate", repr(result))
        self.assertNotIn("private", repr(result))
        self.assertNotIn("irrelevant", repr(result))

    def test_source_normalization_and_strict_action_allowlists(self) -> None:
        rows = [
            row(
                " YouTube ", " Watched ", "y1", "Video", "Channel",
                extra=(
                    "category=Film;published_at=2020-01-01T00:00:00Z;"
                    "watched_at=2026-08-01T12:00:00Z"
                ),
            ),
            row("youtube", "mystery", "y2", "Video", "Channel", extra="category=Film"),
            row("podcast", "mystery", "p1", creator="Show", extra="show=Show"),
            row("healthkit", "sleep", "h1", extra="activity_type=running"),
            row("healthkit", "workout", "h2", extra="activity_type=bedtime"),
            row(" HealthKit ", " Workout ", "h3", extra="activity_type=Running"),
            row("apple_music", "mystery", "m1", "Song", "Artist", extra="genres=Rock"),
        ]
        result = self.read_rows(rows)
        self.assertEqual(len(result.observations), 1)
        youtube = next(item for item in result.observations if item.source == "youtube")
        self.assertEqual(youtube.data_type, "watched")
        self.assertEqual(
            youtube.occurred_at,
            datetime(2026, 8, 1, 12, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(result.excluded_counts["unsupported_youtube_data_type"], 1)
        self.assertEqual(result.excluded_counts["podcast_not_semantically_usable"], 1)
        self.assertEqual(result.excluded_counts["music_not_semantically_usable"], 1)
        self.assertEqual(result.policy_quarantined_counts, {})
        self.assertEqual(result.fitness_records, ())
        self.assertEqual(
            sum(
                value
                for key, value in result.excluded_counts.items()
                if key.startswith("malformed_healthkit_")
            ),
            3,
        )

    def test_music_sources_reject_actions_owned_by_another_connector(self) -> None:
        rows = [
            row(
                "music_library",
                "saved_track",
                "local-invalid",
                "Synthetic track",
                "Synthetic artist",
            ),
            row(
                "spotify",
                "playlist_item",
                "spotify-invalid",
                "Synthetic track",
                "Synthetic artist",
                extra="resource_type=track",
            ),
            row(
                "spotify",
                "followed_artist",
                "spotify-valid",
                "Synthetic artist",
                "Synthetic artist",
                extra="resource_type=artist",
            ),
        ]
        result = self.read_rows(rows)
        self.assertEqual(len(result.observations), 1)
        observation = result.observations[0]
        self.assertEqual((observation.source, observation.action), (
            "spotify",
            "followed_artist",
        ))
        self.assertEqual(result.excluded_counts["music_not_semantically_usable"], 2)
        self.assertTrue(
            all(
                (item.data_type, item.action) in SOURCE_ACTION_PAIRS[item.source]
                for item in result.observations
            )
        )

    def test_verified_resource_namespace_controls_sibling_enrichment(self) -> None:
        rows = [
            row(
                "apple_music", "recently_played", "shared", "Song", "Artist",
                extra=(
                    "resource_type=song;catalog_verified=1;genres=Rock;"
                    "last_played=2026-08-01T12:00:00Z"
                ),
            ),
            row(
                "apple_music", "rating", "shared",
                extra=(
                    "resource_type=song;catalog_verified=1;value=5;"
                    "rating_polarity=positive"
                ),
            ),
            # Same text ID but a different resource namespace: it must not
            # borrow the song's title, creator, genre, or timestamp.
            row(
                "apple_music", "rating", "shared",
                extra=(
                    "resource_type=album;catalog_verified=1;value=5;"
                    "rating_polarity=positive"
                ),
            ),
            # Unverified and empty IDs must never form sibling groups.
            row(
                "apple_music", "rating", "shared",
                extra="value=5;rating_polarity=positive",
            ),
            row("apple_music", "recently_played", "", "Loose Song", "Loose Artist"),
            row(
                "apple_music", "rating", "",
                extra="value=5;rating_polarity=positive",
            ),
        ]
        result = self.read_rows(rows)
        self.assertEqual(len(result.observations), 3)
        self.assertEqual(result.excluded_counts["music_not_semantically_usable"], 3)

        verified = [item for item in result.observations if item.metadata["has_verified_catalog_id"]]
        self.assertEqual(len(verified), 2)
        self.assertEqual({item.content_lineage for item in verified}, {verified[0].content_lineage})
        rating = next(item for item in verified if item.data_type == "rating")
        self.assertIsNone(rating.occurred_at)
        self.assertTrue(rating.allow_external_resolution)
        self.assertTrue(all(term.safe_for_online for term in rating.terms))

        loose = next(item for item in result.observations if item.data_type == "recently_played" and not item.metadata["has_verified_catalog_id"])
        self.assertFalse(loose.allow_external_resolution)
        self.assertTrue(all(not term.safe_for_online for term in loose.terms))

    def test_numeric_rating_without_typed_positive_intent_is_excluded(self) -> None:
        result = self.read_rows(
            [
                row(
                    "apple_music",
                    "rating",
                    "rated-song",
                    "Rated Song",
                    "Example Artist",
                    extra=(
                        "resource_type=song;catalog_verified=1;genres=Rock;value=5"
                    ),
                )
            ]
        )
        self.assertEqual(result.observations, ())
        self.assertEqual(result.excluded_counts["music_not_semantically_usable"], 1)

    def test_provider_plural_resource_types_are_canonicalized(self) -> None:
        rows = [
            row(
                "apple_music", "library_song", "song-1", "Synthetic song", "Artist",
                extra="resource_type=library-songs;catalog_verified=1;genres=Pop",
            )
        ]
        result = self.read_rows(rows)
        self.assertEqual(len(result.observations), 1)
        observation = result.observations[0]
        self.assertTrue(observation.allow_external_resolution)
        self.assertEqual(observation.metadata["catalog_namespace"], "song")

    def test_artist_and_podcast_show_names_keep_their_types(self) -> None:
        result = self.read_rows(
            [
                row(
                    "apple_music",
                    "library_artist",
                    "artist-1",
                    "Example Artist",
                    extra="resource_type=artist;catalog_verified=1",
                ),
                row(
                    "podcast",
                    "followed",
                    "show-1",
                    "Example Show",
                    "Example Publisher",
                    extra="resource_type=show;catalog_verified=1",
                ),
            ]
        )
        artist = next(item for item in result.observations if item.source == "apple_music")
        show = next(item for item in result.observations if item.source == "podcast")
        self.assertEqual(artist.terms[0].type_hint, "creator")
        self.assertIn(
            ("Example Show", "work"),
            {(term.text, term.type_hint) for term in show.terms},
        )
        self.assertNotIn(
            ("Example Publisher", "work"),
            {(term.text, term.type_hint) for term in show.terms},
        )

    def test_bare_podcast_catalog_rows_are_not_user_interest(self) -> None:
        result = self.read_rows(
            [
                row(
                    "podcast",
                    "show",
                    "catalog-show",
                    "Catalog Show",
                    extra="show=Catalog Show;resource_type=show;catalog_verified=1",
                ),
                row(
                    "podcast",
                    "episode",
                    "catalog-episode",
                    "Catalog Episode",
                    extra="show=Catalog Show;resource_type=episode;catalog_verified=1",
                ),
            ]
        )
        self.assertEqual(result.observations, ())
        self.assertEqual(result.excluded_counts["podcast_not_semantically_usable"], 2)

    def test_spotify_podcast_media_cannot_enter_the_music_group(self) -> None:
        result = self.read_rows(
            [
                row(
                    "spotify",
                    "recently_played",
                    "episode-1",
                    "Episode",
                    "Show",
                    extra="resource_type=episode;catalog_verified=1",
                )
            ]
        )
        self.assertEqual(result.observations, ())
        self.assertEqual(
            result.excluded_counts[
                "unsupported_or_missing_spotify_music_resource_type"
            ],
            1,
        )

    def test_external_resolution_requires_verified_public_catalog_identity(self) -> None:
        rows = [
            row("apple_music", "recently_played", "m1", "Song", "Artist", extra="genres=Rock"),
            row(
                "apple_music", "recently_played", "m2", "Song 2", "Artist 2",
                extra="resource_type=song;catalog_verified=1;genres=Rock",
            ),
            row(
                "music_library", "library_song", "local1", "Private Recording", "Family",
                extra="resource_type=song;catalog_verified=1;genre=Speech",
            ),
            row("podcast", "played", "p1", creator="Show", extra="show=Show;categories=Science"),
            row(
                "podcast", "played", "p2", creator="Verified Show",
                extra="show=Verified Show;categories=Science;resource_type=show;catalog_verified=1",
            ),
        ]
        result = self.read_rows(rows)
        by_id = {item.record_fingerprint: item for item in result.observations}
        self.assertEqual(len(by_id), 5)
        allowed = [item for item in result.observations if item.allow_external_resolution]
        self.assertEqual({item.source for item in allowed}, {"apple_music", "podcast"})
        self.assertEqual(len(allowed), 2)
        for item in result.observations:
            self.assertEqual(
                item.allow_external_resolution,
                all(term.safe_for_online for term in item.terms),
            )

    def test_self_asserted_catalog_flag_cannot_enable_egress(self) -> None:
        rows = [
            row(
                "apple_music",
                "recently_played",
                "untrusted-id",
                "Untrusted Song",
                "Untrusted Artist",
                extra="resource_type=song;catalog_verified=1;genres=Rock",
            )
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "untrusted.csv"
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=FIELDS)
                writer.writeheader()
                writer.writerows(rows)
            observation = WrittenExportAdapter().read(path).observations[0]
        self.assertFalse(observation.allow_external_resolution)
        self.assertTrue(all(not term.safe_for_online for term in observation.terms))

    def test_catalog_verifier_never_receives_private_or_descriptive_fields(self) -> None:
        calls: list[tuple[dict[str, str], dict[str, str]]] = []

        def verifier(
            csv_row: dict[str, str],
            extra: dict[str, str],
        ) -> tuple[str, str, str] | None:
            calls.append((csv_row, extra))
            return None

        rows = [
            row(
                "apple_music",
                "recently_played",
                "catalog-item",
                "Descriptive Title",
                "Descriptive Creator",
                extra="resource_type=song;catalog_verified=1;genres=Private Genre",
            ),
            row(
                "apple_calendar",
                "event",
                "private-event",
                "Private Calendar Title",
                extra="booked=1;resource_type=song;catalog_verified=1",
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "verifier-boundary.csv"
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=FIELDS)
                writer.writeheader()
                writer.writerows(rows)
            WrittenExportAdapter(catalog_identity_verifier=verifier).read(path)
        self.assertEqual(len(calls), 2)  # prepass + row dispatch for one music row
        self.assertTrue(all(set(csv_row) == {"source", "item_id"} for csv_row, _ in calls))
        self.assertTrue(all("genres" not in extra for _, extra in calls))

    def test_removed_row_cannot_enrich_an_active_sibling(self) -> None:
        result = self.read_rows(
            [
                row(
                    "apple_music",
                    "recently_played",
                    "shared-removed",
                    "Removed Song",
                    "Removed Artist",
                    extra=(
                        "resource_type=song;catalog_verified=1;genres=Rock;"
                        "removed_by_user=1"
                    ),
                ),
                row(
                    "apple_music",
                    "rating",
                    "shared-removed",
                    extra=(
                        "resource_type=song;catalog_verified=1;"
                        "rating_polarity=positive"
                    ),
                ),
            ]
        )
        self.assertEqual(result.observations, ())
        self.assertEqual(result.excluded_counts["user_removed_observation"], 1)
        self.assertEqual(result.excluded_counts["music_not_semantically_usable"], 1)

    def test_sensitive_calendar_detail_is_withheld_before_term_creation(self) -> None:
        rows = [
            row(
                "apple_calendar", "event", "c1", "Dinner", detail="Psychiatry clinic",
                extra="booked=1;start=2026-08-01T12:00:00Z",
            ),
            row(
                "youtube", "watched", "y1", "Video", "Channel",
                extra="category=Film;watched_at=2026-08-01T12:00:00Z",
            ),
            row(
                "healthkit", "workout", "h1",
                extra="activity_type=running;start=2026-08-01T12:00:00Z",
            ),
        ]
        result = self.read_rows(rows)
        self.assertEqual(result.excluded_counts["sensitive_calendar_event"], 1)
        self.assertEqual({item.source for item in result.observations}, {"youtube"})
        self.assertEqual(result.fitness_records, ())
        self.assertEqual(result.excluded_counts["malformed_healthkit_workout"], 1)
        self.assertTrue(
            all(
                not term.safe_for_global_mining
                for item in result.observations
                for term in item.terms
            )
        )


if __name__ == "__main__":
    unittest.main()
