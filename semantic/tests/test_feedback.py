from __future__ import annotations

import dataclasses
import unittest

from written_ontology.feedback import (
    FeedbackAction,
    FeedbackEvent,
    FeedbackLearner,
)


class FeedbackTests(unittest.TestCase):
    def test_removal_suppresses_without_semantic_negative(self) -> None:
        learner = FeedbackLearner()
        event = FeedbackEvent(
            user_id="u1",
            client_event_id="e1",
            action=FeedbackAction.SUPPRESS,
            assertion_key="affinity_to::italy",
            rule_signature="rule-1",
        )
        effect = learner.apply(event)
        self.assertTrue(effect.suppress_for_user)
        self.assertFalse(effect.semantic_global_negative)
        self.assertEqual(effect.semantic_positive_observation_ids, ())

    def test_removal_event_has_no_reason_field(self) -> None:
        field_names = {field.name for field in dataclasses.fields(FeedbackEvent)}
        self.assertNotIn("reason", field_names)

    def test_addition_labels_mapping_only_when_linked(self) -> None:
        learner = FeedbackLearner(link_validator=lambda event: event.linked_observation_ids)
        linked = learner.apply(
            FeedbackEvent(
                user_id="u1",
                client_event_id="e2",
                action=FeedbackAction.EXPLICIT_ADD,
                assertion_key="concept:shoegaze",
                rule_signature="manual",
                linked_observation_ids=("obs-1",),
            )
        )
        self.assertEqual(linked.semantic_positive_observation_ids, ("obs-1",))
        self.assertFalse(linked.semantic_global_negative)

    def test_unvalidated_links_never_become_semantic_labels(self) -> None:
        learner = FeedbackLearner()
        effect = learner.apply(
            FeedbackEvent(
                user_id="u1",
                client_event_id="untrusted-link",
                action=FeedbackAction.EXPLICIT_ADD,
                assertion_key="concept:shoegaze",
                rule_signature="client-supplied-rule",
                linked_observation_ids=("someone-elses-observation",),
            )
        )
        self.assertEqual(effect.semantic_positive_observation_ids, ())

    def test_client_event_is_idempotent(self) -> None:
        learner = FeedbackLearner()
        event = FeedbackEvent(
            user_id="u1",
            client_event_id="same",
            action=FeedbackAction.SUPPRESS,
            assertion_key="a1",
            rule_signature="r1",
        )
        first = learner.apply(event)
        second = learner.apply(event)
        self.assertEqual(first, second)

    def test_client_event_reuse_with_changed_payload_is_rejected(self) -> None:
        learner = FeedbackLearner()
        learner.apply(
            FeedbackEvent(
                user_id="u1",
                client_event_id="same",
                action=FeedbackAction.SUPPRESS,
                assertion_key="a1",
                rule_signature="r1",
            )
        )
        with self.assertRaises(ValueError):
            learner.apply(
                FeedbackEvent(
                    user_id="u1",
                    client_event_id="same",
                    action=FeedbackAction.SUPPRESS,
                    assertion_key="a2",
                    rule_signature="r2",
                )
            )

    def test_curator_review_requires_exposure_normalized_rejections(self) -> None:
        learner = FeedbackLearner(
            global_review_user_threshold=2,
            minimum_exposed_users=4,
            rejection_rate_threshold=0.50,
            rule_resolver=lambda event: event.rule_signature,
        )
        for user in ("u1", "u2", "u3", "u4"):
            learner.record_exposure("r1", user)
        first = learner.apply(
            FeedbackEvent(
                user_id="u1",
                client_event_id="reject-1",
                action=FeedbackAction.SUPPRESS,
                assertion_key="a1",
                rule_signature="r1",
            )
        )
        second = learner.apply(
            FeedbackEvent(
                user_id="u2",
                client_event_id="reject-2",
                action=FeedbackAction.SUPPRESS,
                assertion_key="a1",
                rule_signature="r1",
            )
        )
        self.assertFalse(first.needs_curator_review)
        self.assertTrue(second.needs_curator_review)

    def test_failed_link_validation_does_not_consume_idempotency_key(self) -> None:
        calls = 0

        def validator(event: FeedbackEvent) -> tuple[str, ...]:
            nonlocal calls
            calls += 1
            return ("not-requested",) if calls == 1 else event.linked_observation_ids

        learner = FeedbackLearner(link_validator=validator)
        event = FeedbackEvent(
            user_id="u1",
            client_event_id="retryable",
            action=FeedbackAction.EXPLICIT_ADD,
            assertion_key="a1",
            rule_signature="r1",
            linked_observation_ids=("owned-observation",),
        )
        with self.assertRaises(ValueError):
            learner.apply(event)
        effect = learner.apply(event)
        self.assertEqual(effect.semantic_positive_observation_ids, ("owned-observation",))

    def test_unknown_action_and_empty_identifiers_are_rejected(self) -> None:
        learner = FeedbackLearner()
        with self.assertRaises(ValueError):
            learner.apply(
                FeedbackEvent(
                    user_id="u1",
                    client_event_id="unknown",
                    action="erase_everything",  # type: ignore[arg-type]
                    assertion_key="a1",
                    rule_signature="r1",
                )
            )

    def test_invalid_review_thresholds_and_rule_signature_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            FeedbackLearner(global_review_user_threshold=0)
        with self.assertRaises(ValueError):
            FeedbackLearner(rejection_rate_threshold=float("nan"))
        with self.assertRaises(ValueError):
            FeedbackLearner().apply(
                FeedbackEvent(
                    user_id="u1",
                    client_event_id="bad-rule",
                    action=FeedbackAction.SUPPRESS,
                    assertion_key="a1",
                    rule_signature="",
                )
            )
        learner = FeedbackLearner()
        with self.assertRaises(ValueError):
            learner.apply(
                FeedbackEvent(
                    user_id="",
                    client_event_id="empty-user",
                    action=FeedbackAction.SUPPRESS,
                    assertion_key="a1",
                    rule_signature="r1",
                )
            )


if __name__ == "__main__":
    unittest.main()
