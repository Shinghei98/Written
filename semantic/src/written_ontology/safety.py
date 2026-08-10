from __future__ import annotations

import re
import math
from dataclasses import dataclass

from .models import Concept, ConceptEdge, Observation, Term


PROHIBITED_INFERRED_KINDS = {
    "identity",
    "health_condition",
    "religion",
    "political_belief",
    "sexual_orientation",
    "ethnicity",
    "nationality",
    "ancestry",
}

ALLOWED_INFERRED_KINDS = {
    "activity",
    "affinity",
    "creator",
    "channel",
    "cuisine",
    "culture",
    "event",
    "genre",
    "hub",
    "language",
    "medium",
    "organization",
    "place",
    "sport",
    "topic",
    "work",
}

PROHIBITED_KEY_FRAGMENTS = {
    "addiction",
    "anxiety",
    "ancestry",
    "bmi",
    "chronic_condition",
    "depression",
    "nationality",
    "native_language",
    "ethnicity",
    "fertility",
    "religion",
    "politic",
    "pregnancy",
    "menstrual",
    "medication",
    "mental_health",
    "sexual_orientation",
    "sleep_disorder",
    "diagnosis",
    "disability",
    "eating_disorder",
    "immigration",
    "family_root",
    "home_base",
    "hometown",
    "lives_in",
}

# These sources may participate in a local, purpose-limited service, but their
# terms may never leave the private boundary or enter global/population term
# mining. This is an egress rule, not an ingestion quarantine.
NO_EGRESS_OR_GLOBAL_MINING_SOURCES = {
    "health",
    "healthkit",
    "apple_health",
    "apple_healthkit",
    "motion_fitness",
}

ALLOWED_INFERENCE_PREDICATES = {
    "broader",
    "supports_cultural_affinity_candidate",
    "about",
}

# Fail-closed filter for calendar titles before local semantic extraction. This
# is a supplemental guard, not a claim that the list captures every sensitive
# expression or language.
_PRIVATE_CALENDAR_PATTERN = re.compile(
    r"\b(?:therapy|therapist|psychiatr|surgery|post[ -]?op|outpatient|"
    r"doctor|dentist|hospital|clinic|diagnos|medication|rehab|worship|"
    r"church|mosque|synagogue|campaign|ballot|visa|immigration)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class PolicyDecision:
    allowed: bool
    code: str


class InferenceSafetyPolicy:
    @staticmethod
    def _has_verified_public_catalog_identity(observation: Observation) -> bool:
        if not isinstance(observation, Observation) or not isinstance(
            observation.metadata, dict
        ):
            return False
        if observation.source not in {
            "apple_music",
            "spotify",
            "apple_podcasts",
            "podcast",
        }:
            return False
        return (
            observation.metadata.get("has_verified_catalog_id") is True
            and bool(observation.metadata.get("catalog_namespace"))
        )

    def concept_is_inferable(self, concept: Concept) -> PolicyDecision:
        if not isinstance(concept, Concept):
            return PolicyDecision(False, "malformed_concept")
        if not all(
            isinstance(value, str)
            for value in (concept.key, concept.kind, concept.sensitivity, concept.status)
        ):
            return PolicyDecision(False, "malformed_concept")
        kind = concept.kind.casefold().strip().replace("-", "_").replace(" ", "_")
        sensitivity = concept.sensitivity.casefold().strip()
        status = concept.status.casefold().strip()
        lowered_key = concept.key.casefold()
        if status != "active":
            return PolicyDecision(False, "concept_not_active")
        if kind in PROHIBITED_INFERRED_KINDS:
            return PolicyDecision(False, "prohibited_concept_kind")
        if kind not in ALLOWED_INFERRED_KINDS:
            return PolicyDecision(False, "unknown_concept_kind")
        if any(fragment in lowered_key for fragment in PROHIBITED_KEY_FRAGMENTS):
            return PolicyDecision(False, "prohibited_identity_or_sensitive_key")
        if sensitivity != "ordinary":
            return PolicyDecision(False, "nonordinary_or_unknown_sensitivity")
        if concept.inference_policy.value in {"explicit_only", "prohibited"}:
            return PolicyDecision(False, "explicit_only_or_prohibited")
        return PolicyDecision(True, "allowed")

    def edge_is_inferable(self, edge: ConceptEdge) -> PolicyDecision:
        if not isinstance(edge, ConceptEdge):
            return PolicyDecision(False, "malformed_edge")
        if not all(
            isinstance(value, str)
            for value in (
                edge.subject_key,
                edge.predicate_key,
                edge.object_key,
                edge.status,
            )
        ):
            return PolicyDecision(False, "malformed_edge")
        if (
            not isinstance(edge.confidence, (int, float))
            or isinstance(edge.confidence, bool)
            or not math.isfinite(edge.confidence)
            or not 0.0 <= edge.confidence <= 1.0
        ):
            return PolicyDecision(False, "invalid_edge_confidence")
        if edge.status != "active":
            return PolicyDecision(False, "inactive_edge")
        if edge.predicate_key not in ALLOWED_INFERENCE_PREDICATES:
            return PolicyDecision(False, "predicate_not_whitelisted")
        return PolicyDecision(True, "allowed")

    def term_may_leave_device_boundary(self, observation: Observation, term: Term) -> bool:
        if not isinstance(observation, Observation) or not isinstance(term, Term):
            return False
        if observation.source in NO_EGRESS_OR_GLOBAL_MINING_SOURCES:
            return False
        if observation.privacy_class != "public_catalog":
            return False
        return (
            self._has_verified_public_catalog_identity(observation)
            and observation.allow_external_resolution is True
            and term.safe_for_online is True
        )

    def calendar_title_is_sensitive(self, title: str) -> bool:
        if not isinstance(title, str):
            return True
        return bool(_PRIVATE_CALENDAR_PATTERN.search(title))

    def term_is_safe_for_global_mining(self, observation: Observation, term: Term) -> bool:
        """Apply a second fail-closed gate even when an adapter marks a term public."""
        if not isinstance(observation, Observation) or not isinstance(term, Term):
            return False
        if observation.source == "youtube" or observation.source in NO_EGRESS_OR_GLOBAL_MINING_SOURCES:
            return False
        if (
            term.safe_for_global_mining is not True
            or observation.privacy_class != "public_catalog"
        ):
            return False
        if not self._has_verified_public_catalog_identity(observation):
            return False
        if not isinstance(term.normalized, str):
            return False
        normalized = term.normalized.casefold()
        if _PRIVATE_CALENDAR_PATTERN.search(normalized):
            return False
        return not any(fragment in normalized for fragment in PROHIBITED_KEY_FRAGMENTS)
