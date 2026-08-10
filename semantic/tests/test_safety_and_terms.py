from __future__ import annotations

import unittest
from dataclasses import replace

from written_ontology.demo import fixture_observations
from written_ontology.models import Concept, InferencePolicyName, Term
from written_ontology.safety import InferenceSafetyPolicy
from written_ontology.term_mining import EmergentTermMiner


class SafetyAndTermTests(unittest.TestCase):
    def test_sensitive_identity_is_blocked_even_if_marked_inferable(self) -> None:
        concept = Concept(
            key="identity:italian_ancestry",
            label="Italian ancestry",
            kind="identity",
            sensitivity="sensitive",
            inference_policy=InferencePolicyName.INFERABLE,
        )
        self.assertFalse(InferenceSafetyPolicy().concept_is_inferable(concept).allowed)

    def test_health_status_keys_are_blocked_even_if_mislabeled_ordinary(self) -> None:
        policy = InferenceSafetyPolicy()
        for key in (
            "topic:depression",
            "topic:pregnancy",
            "topic:sleep_disorder",
            "topic:eating_disorder",
        ):
            concept = Concept(
                key=key,
                label="Synthetic sensitive concept",
                kind="topic",
                sensitivity="ordinary",
                inference_policy=InferencePolicyName.INFERABLE,
            )
            self.assertFalse(policy.concept_is_inferable(concept).allowed)

    def test_healthkit_provenance_cannot_leave_or_enter_global_mining(self) -> None:
        policy = InferenceSafetyPolicy()
        music = fixture_observations()[0]
        health = replace(music, source="healthkit")
        term = health.terms[0]
        self.assertFalse(policy.term_may_leave_device_boundary(health, term))
        self.assertFalse(policy.term_is_safe_for_global_mining(health, term))

    def test_private_calendar_terms_do_not_enter_global_mining(self) -> None:
        miner = EmergentTermMiner(minimum_distinct_users=5)
        calendar = [item for item in fixture_observations() if item.independence_group == "calendar"][0]
        for user in ("u1", "u2", "u3"):
            miner.add_observation(user, calendar)
        self.assertEqual(miner.terms(), ())

    def test_term_threshold_counts_users_not_observations(self) -> None:
        miner = EmergentTermMiner(minimum_distinct_users=5)
        music = fixture_observations()[0]
        for _ in range(100):
            miner.add_observation("one-user", music)
        self.assertEqual(miner.terms(), ())
        self.assertEqual(
            miner.private_count_summary(),
            {
                "distinct_term_keys": 1,
                "below_threshold_term_keys": 1,
                "occurrences": 100,
            },
        )

    def test_pair_support_must_meet_full_privacy_threshold(self) -> None:
        miner = EmergentTermMiner(minimum_distinct_users=5)
        music = fixture_observations()[0]
        for user in ("u1", "u2", "u3", "u4", "u5"):
            miner.add_observation(user, music)
        second = replace(
            music,
            id="second-term",
            terms=(
                Term(
                    text="Italian musical culture",
                    normalized="italian musical culture",
                    role="genre_or_culture",
                    source_field="fixture",
                    type_hint="topic",
                    safe_for_online=True,
                    safe_for_global_mining=True,
                ),
            ),
        )
        for user in ("u1", "u2", "u6", "u7", "u8"):
            miner.add_observation(user, second)
        self.assertEqual(miner.relation_proposals(), ())

    def test_global_term_privacy_floor_cannot_be_lowered(self) -> None:
        with self.assertRaises(ValueError):
            EmergentTermMiner(minimum_distinct_users=4)
        with self.assertRaises(ValueError):
            EmergentTermMiner(minimum_distinct_users=float("nan"))  # type: ignore[arg-type]

    def test_case_variant_identity_and_unknown_sensitivity_fail_closed(self) -> None:
        policy = InferenceSafetyPolicy()
        identity = Concept(
            key="identity:mixed_case",
            label="Mixed case identity",
            kind="Identity",
            sensitivity="Ordinary",
            inference_policy=InferencePolicyName.INFERABLE,
        )
        unknown = Concept(
            key="topic:unknown_sensitivity",
            label="Unknown sensitivity",
            kind="topic",
            sensitivity="confidential",
            inference_policy=InferencePolicyName.INFERABLE,
        )
        self.assertFalse(policy.concept_is_inferable(identity).allowed)
        self.assertFalse(policy.concept_is_inferable(unknown).allowed)

    def test_string_false_global_mining_flag_is_not_truthy(self) -> None:
        music = fixture_observations()[0]
        malformed = replace(
            music,
            terms=(
                replace(
                    music.terms[0],
                    safe_for_global_mining="false",  # type: ignore[arg-type]
                ),
            ),
        )
        miner = EmergentTermMiner()
        for user in ("u1", "u2", "u3", "u4", "u5"):
            miner.add_observation(user, malformed)
        self.assertEqual(miner.terms(), ())


if __name__ == "__main__":
    unittest.main()
