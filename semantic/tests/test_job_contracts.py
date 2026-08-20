from __future__ import annotations

import unittest
from dataclasses import FrozenInstanceError
from types import MappingProxyType
from uuid import UUID

from written_ontology.job_contracts import (
    BuildMemoriesPayload,
    ClassifyCalendarPayload,
    ComputeDyadPayload,
    DeriveFitnessHabitsPayload,
    JOB_CONTRACTS,
    JOB_CONTRACT_REGISTRY,
    JobContractError,
    JobType,
    MapObservationPayload,
    MineTermsPayload,
    REQUIRED_JOB_TYPES,
    RecomputeUserPayload,
    MintVocabularyPayload,
    RefreshExternalEntityPayload,
    RenderBioPayload,
    RenderIcebreakerPayload,
    ResolveYouTubeChannelPayload,
    validate_job_payload,
    ExtractMentionsPayload,
    ResolveMentionPayload,
    BuildCandidateOverlayPayload,
    AggregateTermCandidatesPayload,
    BuildReviewItemsPayload,
    ApplyFeedbackPayload,
    AggregateFeedbackPayload,
    EvaluateReleasePayload,
    ProcessMintRequestsPayload,
)


def uid(number: int) -> str:
    return f"00000000-0000-0000-0000-{number:012x}"


USER = uid(1)
VIEWER = uid(2)
SUBJECT = uid(3)


def valid_payloads() -> dict[str, dict[str, object]]:
    """Independent objects: mutation in a negative test cannot leak."""

    return {
        "map_observation": {
            "observation_id": uid(10),
            "user_id": USER,
            "input_revision": 7,
            "semantic_run_id": uid(11),
            "ontology_version_id": uid(12),
            "resolver_model_id": uid(13),
        },
        "classify_calendar": {
            "observation_id": uid(20),
            "user_id": USER,
            "input_revision": 7,
            "ontology_version_id": uid(21),
            "classifier_model_id": uid(22),
        },
        "resolve_youtube_channel": {
            "youtube_channel_row_id": uid(30),
            "youtube_channel_id": "UC" + "A" * 22,
            "ontology_version_id": uid(31),
            "resolver_model_id": uid(32),
            "resolution_version": "youtube-resolver-v0.2.0",
        },
        "recompute_user": {
            "user_id": USER,
            "input_revision": 7,
            "ontology_version_id": uid(40),
            "resolver_model_id": uid(41),
            "scorer_model_id": uid(42),
        },
        "build_memories": {
            "user_id": USER,
            "input_revision": 7,
            "ontology_version_id": uid(50),
            "builder_model_id": uid(51),
            "presentation_version": "memories-v0.2.0",
        },
        "compute_dyad": {
            "viewer_user_id": VIEWER,
            "subject_user_id": SUBJECT,
            "viewer_revision": 5,
            "subject_revision": 9,
            "ontology_version_id": uid(60),
            "ranker_model_id": uid(61),
            "run_purpose": "both",
            "data_use_purpose": "general_social",
        },
        "render_bio": {
            "dyad_run_id": uid(70),
            "viewer_user_id": VIEWER,
            "subject_user_id": SUBJECT,
            "viewer_revision": 5,
            "subject_revision": 9,
            "renderer_model_id": uid(71),
            "presentation_version": "bio-v0.2.0",
        },
        "render_icebreaker": {
            "match_authorization_id": uid(80),
            "dyad_run_id": uid(81),
            "viewer_user_id": VIEWER,
            "subject_user_id": SUBJECT,
            "viewer_revision": 5,
            "subject_revision": 9,
            "renderer_model_id": uid(82),
            "template_version": "icebreaker-v0.2.0",
        },
        "mine_terms": {
            "aggregate_snapshot_id": uid(90),
            "base_ontology_version_id": uid(91),
            "miner_model_id": uid(92),
            "minimum_distinct_users": 5,
            "mining_policy_version": "privacy-floor-v1",
        },
        "refresh_external_entity": {
            "external_entity_id": uid(100),
            "refresher_version": "external-refresh-v1",
        },
        "derive_fitness_habits": {
            "user_id": USER,
            "input_revision": 7,
            "fitness_snapshot_id": uid(110),
            "builder_model_id": uid(111),
            "policy_version": "written-healthkit-fitness-v1.0.0",
        },
    }


PAYLOAD_TYPES = {
    "map_observation": MapObservationPayload,
    "classify_calendar": ClassifyCalendarPayload,
    "resolve_youtube_channel": ResolveYouTubeChannelPayload,
    "recompute_user": RecomputeUserPayload,
    "build_memories": BuildMemoriesPayload,
    "compute_dyad": ComputeDyadPayload,
    "render_bio": RenderBioPayload,
    "render_icebreaker": RenderIcebreakerPayload,
    "mine_terms": MineTermsPayload,
    "refresh_external_entity": RefreshExternalEntityPayload,
    # Armed by a distillation and started after a quiet window; carries a
    # user and nothing else, because the debounce guarantees more revisions
    # arrive between arming and claiming.
    "mint_vocabulary": MintVocabularyPayload,
    "derive_fitness_habits": DeriveFitnessHabitsPayload,
    # The candidate overlay's pipeline, in the order it runs. `extract_mentions`
    # is the model lane and declines while the contract disables the overlay;
    # the other seven are the exact lane and run against mentions the legacy
    # resolver has already mined.
    "extract_mentions": ExtractMentionsPayload,
    "resolve_mention": ResolveMentionPayload,
    "build_candidate_overlay": BuildCandidateOverlayPayload,
    "aggregate_term_candidates": AggregateTermCandidatesPayload,
    "build_review_items": BuildReviewItemsPayload,
    "apply_feedback": ApplyFeedbackPayload,
    # The one fleet-wide job: no user, by design and by payload validator.
    "aggregate_feedback": AggregateFeedbackPayload,
    "evaluate_release": EvaluateReleasePayload,
    # The other fleet-wide job, and no user for the same reason: minting writes
    # shared vocabulary, so a queue row naming an account would suggest the
    # catalogue is per-person.
    "process_mint_requests": ProcessMintRequestsPayload,
}


class RegistryTests(unittest.TestCase):
    def test_registry_is_complete_and_exact(self) -> None:
        expected = set(PAYLOAD_TYPES)
        self.assertEqual(REQUIRED_JOB_TYPES, expected)
        self.assertEqual(set(JOB_CONTRACTS), expected)
        self.assertEqual(set(JOB_CONTRACT_REGISTRY.job_types), expected)
        self.assertEqual({item.value for item in JobType}, expected)

    def test_registry_exposes_schema_metadata_not_handlers(self) -> None:
        for job_type, payload_type in PAYLOAD_TYPES.items():
            contract = JOB_CONTRACTS[job_type]
            self.assertIs(contract.payload_type, payload_type)
            self.assertEqual(contract.contract_version, 1)
            self.assertTrue(contract.purpose)
            self.assertTrue(contract.required_fields)
            self.assertFalse(hasattr(contract, "handler"))

    def test_registry_mapping_is_read_only(self) -> None:
        self.assertIsInstance(JOB_CONTRACTS, MappingProxyType)
        with self.assertRaises(TypeError):
            JOB_CONTRACTS["future_job"] = JOB_CONTRACTS["map_observation"]  # type: ignore[index]

    def test_unknown_job_type_fails_closed(self) -> None:
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("future_job", {})
        self.assertEqual(caught.exception.code, "unknown_job_type")
        self.assertNotIn("future_job", str(caught.exception))


class ValidPayloadTests(unittest.TestCase):
    def test_every_required_job_returns_its_typed_immutable_payload(self) -> None:
        for job_type, raw in valid_payloads().items():
            with self.subTest(job_type=job_type):
                parsed = validate_job_payload(job_type, raw)
                self.assertIsInstance(parsed, PAYLOAD_TYPES[job_type])
                self.assertEqual(parsed.as_payload(), raw)
                first_field = next(iter(JOB_CONTRACTS[job_type].required_fields))
                with self.assertRaises((FrozenInstanceError, AttributeError)):
                    setattr(parsed, first_field, None)

    def test_uuid_fields_are_normalized_to_uuid_objects(self) -> None:
        parsed = validate_job_payload(
            "classify_calendar", valid_payloads()["classify_calendar"]
        )
        self.assertIsInstance(parsed, ClassifyCalendarPayload)
        self.assertIsInstance(parsed.observation_id, UUID)
        self.assertIsInstance(parsed.classifier_model_id, UUID)

    def test_optional_embedding_model_is_typed_or_omitted(self) -> None:
        raw = valid_payloads()["recompute_user"]
        without = validate_job_payload("recompute_user", raw)
        self.assertIsInstance(without, RecomputeUserPayload)
        self.assertIsNone(without.embedding_model_id)
        self.assertNotIn("embedding_model_id", without.as_payload())

        raw["embedding_model_id"] = uid(43)
        with_embedding = validate_job_payload("recompute_user", raw)
        self.assertEqual(with_embedding.embedding_model_id, UUID(uid(43)))
        self.assertEqual(with_embedding.as_payload(), raw)

        raw["embedding_model_id"] = None
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("recompute_user", raw)
        self.assertEqual(caught.exception.code, "invalid_uuid")

    def test_zero_is_a_valid_initial_revision(self) -> None:
        raw = valid_payloads()["compute_dyad"]
        raw["viewer_revision"] = 0
        raw["subject_revision"] = 0
        parsed = validate_job_payload("compute_dyad", raw)
        self.assertEqual(parsed.viewer_revision, 0)
        self.assertEqual(parsed.subject_revision, 0)

    def test_queue_user_can_be_cross_checked_before_handler_dispatch(self) -> None:
        raw = valid_payloads()["map_observation"]
        parsed = validate_job_payload(
            "map_observation", raw, queue_user_id=USER
        )
        self.assertEqual(parsed.user_id, UUID(USER))

        with self.assertRaises(JobContractError) as caught:
            validate_job_payload(
                "map_observation", raw, queue_user_id=SUBJECT
            )
        self.assertEqual(caught.exception.code, "queue_user_mismatch")

    def test_dyadic_queue_owner_is_the_directional_viewer(self) -> None:
        raw = valid_payloads()["render_bio"]
        validate_job_payload("render_bio", raw, queue_user_id=VIEWER)
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("render_bio", raw, queue_user_id=SUBJECT)
        self.assertEqual(caught.exception.code, "queue_user_mismatch")

    def test_fitness_job_uses_only_durable_ids_and_pinned_versions(self) -> None:
        raw = valid_payloads()["derive_fitness_habits"]
        parsed = validate_job_payload(
            "derive_fitness_habits", raw, queue_user_id=USER
        )
        self.assertIsInstance(parsed, DeriveFitnessHabitsPayload)
        for forbidden in ("steps", "workout", "sleep_times", "heart_rate"):
            invalid = dict(raw)
            invalid[forbidden] = "private"
            with self.assertRaises(JobContractError):
                validate_job_payload("derive_fitness_habits", invalid)
        stale_policy = dict(raw)
        stale_policy["policy_version"] = "written-healthkit-fitness-v0.9.0"
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("derive_fitness_habits", stale_policy)
        self.assertEqual(caught.exception.code, "unsupported_fitness_policy_version")


class ClosedSchemaAndPrivacyTests(unittest.TestCase):
    def test_payload_must_be_an_object(self) -> None:
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("map_observation", [])  # type: ignore[arg-type]
        self.assertEqual(caught.exception.code, "payload_not_object")

    def test_safe_but_unknown_keys_are_rejected(self) -> None:
        raw = valid_payloads()["build_memories"]
        raw["debug_mode"] = False
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("build_memories", raw)
        self.assertEqual(caught.exception.code, "unknown_payload_field")
        self.assertEqual(caught.exception.field, "debug_mode")

    def test_arbitrary_unknown_key_is_not_echoed_in_persistable_error_text(self) -> None:
        private_key = "alice_secret_relationship"
        raw = valid_payloads()["build_memories"]
        raw[private_key] = True
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("build_memories", raw)
        self.assertEqual(caught.exception.code, "unknown_payload_field")
        self.assertNotIn(private_key, str(caught.exception))

    def test_raw_calendar_itinerary_and_people_fields_are_explicitly_rejected(self) -> None:
        forbidden = (
            "raw_text",
            "private_text",
            "event_title",
            "event_notes",
            "itinerary",
            "route",
            "flight_number",
            "booking_reference",
            "location_text",
            "departure_at",
            "arrival_at",
            "attendees",
            "organizer",
            "medical",
            "birthday",
            "funeral",
            "meeting",
        )
        for field in forbidden:
            with self.subTest(field=field):
                raw = valid_payloads()["classify_calendar"]
                raw[field] = "do not put this on the queue"
                with self.assertRaises(JobContractError) as caught:
                    validate_job_payload("classify_calendar", raw)
                self.assertEqual(caught.exception.code, "forbidden_private_field")

    def test_recursive_privacy_scan_precedes_unknown_field_handling(self) -> None:
        raw = valid_payloads()["classify_calendar"]
        raw["future_metadata"] = {
            "apparently_safe": [{"itinerary_text": "secret route"}]
        }
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("classify_calendar", raw)
        self.assertEqual(caught.exception.code, "forbidden_private_field")
        self.assertEqual(caught.exception.field, "itinerary_text")

    def test_privacy_error_does_not_echo_private_values(self) -> None:
        secret = "Passenger Alice has a medical visit on flight ZZ999"
        raw = valid_payloads()["classify_calendar"]
        raw["raw_event"] = secret
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("classify_calendar", raw)
        self.assertNotIn(secret, str(caught.exception))
        self.assertNotIn("Alice", str(caught.exception))

    def test_non_string_payload_keys_are_rejected(self) -> None:
        raw = valid_payloads()["map_observation"]
        raw[1] = "value"  # type: ignore[index]
        with self.assertRaises(JobContractError) as caught:
            validate_job_payload("map_observation", raw)
        self.assertEqual(caught.exception.code, "invalid_payload_key")


class IdentifierRevisionAndVersionTests(unittest.TestCase):
    def test_every_uuid_field_rejects_malformed_noncanonical_and_typed_uuid_values(self) -> None:
        for job_type, raw in valid_payloads().items():
            contract = JOB_CONTRACTS[job_type]
            uuid_fields = [
                field
                for field in contract.allowed_fields
                if field.endswith("_id") and field != "youtube_channel_id"
            ]
            for field in uuid_fields:
                with self.subTest(job_type=job_type, field=field):
                    invalid = dict(raw)
                    invalid[field] = "not-a-uuid"
                    with self.assertRaises(JobContractError) as caught:
                        validate_job_payload(job_type, invalid)
                    self.assertEqual(caught.exception.code, "invalid_uuid")

        raw = valid_payloads()["map_observation"]
        raw["observation_id"] = uid(10).upper()
        with self.assertRaises(JobContractError) as uppercase:
            validate_job_payload("map_observation", raw)
        self.assertEqual(uppercase.exception.code, "invalid_uuid")

        raw["observation_id"] = UUID(uid(10))
        with self.assertRaises(JobContractError) as non_json:
            validate_job_payload("map_observation", raw)
        self.assertEqual(non_json.exception.code, "invalid_uuid")

    def test_revisions_reject_bool_string_negative_and_bigint_overflow(self) -> None:
        revisions = {
            "map_observation": ("input_revision",),
            "classify_calendar": ("input_revision",),
            "recompute_user": ("input_revision",),
            "build_memories": ("input_revision",),
            "compute_dyad": ("viewer_revision", "subject_revision"),
            "render_bio": ("viewer_revision", "subject_revision"),
            "render_icebreaker": ("viewer_revision", "subject_revision"),
            "derive_fitness_habits": ("input_revision",),
        }
        for job_type, fields in revisions.items():
            for field in fields:
                for value in (True, "7", -1, 1 << 63):
                    with self.subTest(job_type=job_type, field=field, value=value):
                        raw = valid_payloads()[job_type]
                        raw[field] = value
                        with self.assertRaises(JobContractError) as caught:
                            validate_job_payload(job_type, raw)
                        self.assertEqual(caught.exception.code, "invalid_revision")

    def test_dyadic_jobs_require_two_explicit_revision_fields(self) -> None:
        for job_type in ("compute_dyad", "render_bio", "render_icebreaker"):
            for missing in ("viewer_revision", "subject_revision"):
                with self.subTest(job_type=job_type, missing=missing):
                    raw = valid_payloads()[job_type]
                    del raw[missing]
                    with self.assertRaises(JobContractError) as caught:
                        validate_job_payload(job_type, raw)
                    self.assertEqual(caught.exception.code, "missing_payload_field")
                    self.assertEqual(caught.exception.field, missing)

            raw = valid_payloads()[job_type]
            del raw["viewer_revision"]
            del raw["subject_revision"]
            raw["revisions"] = {VIEWER: 5, SUBJECT: 9}
            with self.assertRaises(JobContractError) as caught:
                validate_job_payload(job_type, raw)
            self.assertEqual(caught.exception.code, "unknown_payload_field")

    def test_same_user_is_rejected_for_compute_and_both_render_jobs(self) -> None:
        for job_type in ("compute_dyad", "render_bio", "render_icebreaker"):
            with self.subTest(job_type=job_type):
                raw = valid_payloads()[job_type]
                raw["subject_user_id"] = raw["viewer_user_id"]
                with self.assertRaises(JobContractError) as caught:
                    validate_job_payload(job_type, raw)
                self.assertEqual(caught.exception.code, "same_user_dyad")

    def test_invalid_youtube_channel_id_is_rejected(self) -> None:
        for channel_id in ("", "A" * 24, "UCtoo-short", "UC" + "!" * 22):
            with self.subTest(channel_id=channel_id):
                raw = valid_payloads()["resolve_youtube_channel"]
                raw["youtube_channel_id"] = channel_id
                with self.assertRaises(JobContractError) as caught:
                    validate_job_payload("resolve_youtube_channel", raw)
                self.assertEqual(
                    caught.exception.code, "invalid_youtube_channel_id"
                )

    def test_all_human_readable_versions_are_bounded_safe_tokens(self) -> None:
        version_fields = {
            "resolve_youtube_channel": "resolution_version",
            "build_memories": "presentation_version",
            "render_bio": "presentation_version",
            "render_icebreaker": "template_version",
            "mine_terms": "mining_policy_version",
            "refresh_external_entity": "refresher_version",
            "derive_fitness_habits": "policy_version",
        }
        for job_type, field in version_fields.items():
            for value in ("", " has-space", "v1/unsafe", "v" * 81, 1):
                with self.subTest(job_type=job_type, field=field, value=value):
                    raw = valid_payloads()[job_type]
                    raw[field] = value
                    with self.assertRaises(JobContractError) as caught:
                        validate_job_payload(job_type, raw)
                    self.assertEqual(caught.exception.code, "invalid_version")

    def test_term_mining_privacy_floor_is_not_configurable_below_five(self) -> None:
        for value in (False, 4, -1, 5.0, 1 << 31):
            with self.subTest(value=value):
                raw = valid_payloads()["mine_terms"]
                raw["minimum_distinct_users"] = value
                with self.assertRaises(JobContractError) as caught:
                    validate_job_payload("mine_terms", raw)
                self.assertEqual(caught.exception.code, "invalid_privacy_threshold")

    def test_dyad_data_use_purpose_is_closed(self) -> None:
        for value in ("", "dating_profile", "fitness", 1):
            raw = valid_payloads()["compute_dyad"]
            raw["data_use_purpose"] = value
            with self.assertRaises(JobContractError) as caught:
                validate_job_payload("compute_dyad", raw)
            self.assertEqual(caught.exception.code, "invalid_data_use_purpose")


if __name__ == "__main__":
    unittest.main()
