"""Product-surface algorithms for Written's typed assertion graph.

The module deliberately has no database or model-provider dependencies.  It is
the pure decision layer between versioned semantic assertions and three
consumers: Memories, viewer-conditioned bios, and icebreakers.  SQL adapters
can construct the dataclasses here without giving this layer access to raw
observations.

Scores in this module are bounded ranking quantities, not probabilities.
"""

from __future__ import annotations

import math
from collections import defaultdict, deque
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Iterable, Mapping

from .healthkit import canonical_healthkit_source


ALLOWED_SURFACES = frozenset({"memories", "matching", "bio", "icebreaker"})
ALLOWED_DATA_USE_PURPOSES = frozenset({"general_social", "fitness_connection"})


class Explicitness(StrEnum):
    INFERRED = "inferred"
    CONFIRMED = "confirmed"
    USER_ADDED = "user_added"


class PermissionUse(StrEnum):
    SELECT = "select"
    NAME = "name"
    EXPLAIN = "explain"


@dataclass(frozen=True, slots=True)
class SurfaceGrant:
    """Independent permission dimensions for one product surface.

    Permission is monotone: an explanation necessarily names a concept, and a
    named concept necessarily participated in selection.  A grant may still
    allow private selection while forbidding both naming and provenance text.
    """

    surface: str
    allow_selection: bool
    allow_naming: bool = False
    allow_explanation: bool = False

    def __post_init__(self) -> None:
        if self.surface not in ALLOWED_SURFACES:
            raise ValueError("surface grant is not recognized")
        if any(
            type(value) is not bool
            for value in (
                self.allow_selection,
                self.allow_naming,
                self.allow_explanation,
            )
        ):
            raise ValueError("surface grant values must be booleans")
        if self.allow_naming and not self.allow_selection:
            raise ValueError("naming permission requires selection permission")
        if self.allow_explanation and not self.allow_naming:
            raise ValueError("explanation permission requires naming permission")

    def allows(self, use: PermissionUse | str) -> bool:
        try:
            normalized = PermissionUse(use)
        except (TypeError, ValueError):
            return False
        return {
            PermissionUse.SELECT: self.allow_selection,
            PermissionUse.NAME: self.allow_naming,
            PermissionUse.EXPLAIN: self.allow_explanation,
        }[normalized]


def normalize_surface_grants(
    legacy_permissions: Iterable[str],
    grants: Iterable[SurfaceGrant],
) -> tuple[frozenset[str], tuple[SurfaceGrant, ...]]:
    """Normalize grants while preserving the original coarse API.

    A legacy permission means full permission only when no explicit grant for
    that surface is supplied.  New integrations should always provide grants.
    """
    legacy = frozenset(legacy_permissions)
    if not legacy <= ALLOWED_SURFACES:
        raise ValueError("surface permission is not recognized")
    explicit: dict[str, SurfaceGrant] = {}
    for grant in grants:
        if not isinstance(grant, SurfaceGrant):
            raise ValueError("surface grants must be SurfaceGrant instances")
        if grant.surface in explicit:
            raise ValueError("surface may have only one explicit grant")
        explicit[grant.surface] = grant
    for surface in legacy:
        explicit.setdefault(
            surface,
            SurfaceGrant(
                surface=surface,
                allow_selection=True,
                allow_naming=True,
                allow_explanation=True,
            ),
        )
    permissions = frozenset(
        surface for surface, grant in explicit.items() if grant.allow_selection
    )
    return permissions, tuple(explicit[key] for key in sorted(explicit))


def youtube_policy_surface_grants(
    *,
    cross_source_fusion: bool,
    bio_surface: bool,
    icebreaker_surface: bool,
    explanation_surfaces: Iterable[str] = (),
) -> tuple[SurfaceGrant, ...]:
    """Translate YouTube approval gates into non-launderable surface grants.

    Private Memories review is allowed. Matching requires cross-source fusion;
    bio/icebreaker also require their specific approval. Supporting evidence is
    not explainable unless the caller separately allowlists that surface.
    """
    if any(
        type(value) is not bool
        for value in (cross_source_fusion, bio_surface, icebreaker_surface)
    ):
        raise ValueError("YouTube policy gates must be booleans")
    explanations = frozenset(explanation_surfaces)
    if not explanations <= ALLOWED_SURFACES:
        raise ValueError("YouTube explanation surface is not recognized")
    enabled = {
        "memories": True,
        "matching": cross_source_fusion,
        "bio": cross_source_fusion and bio_surface,
        "icebreaker": cross_source_fusion and icebreaker_surface,
    }
    return tuple(
        SurfaceGrant(
            surface=surface,
            allow_selection=allowed,
            allow_naming=allowed,
            allow_explanation=allowed and surface in explanations,
        )
        for surface, allowed in enabled.items()
    )


def healthkit_fitness_surface_grants(
    *,
    fitness_matching_opt_in: bool,
    bio_naming_opt_in: bool,
    icebreaker_naming_opt_in: bool,
    explanation_surfaces: Iterable[str] = (),
) -> tuple[SurfaceGrant, ...]:
    """Create independent user grants for purpose-limited fitness discovery.

    Owner Memories review is always available for a validated candidate.
    Matching, bio naming, and icebreaker naming are separate explicit choices.
    Exact Health measurements are never explanatory facts; callers may explain
    only controlled habit labels.
    """

    if any(
        type(value) is not bool
        for value in (
            fitness_matching_opt_in,
            bio_naming_opt_in,
            icebreaker_naming_opt_in,
        )
    ):
        raise ValueError("HealthKit fitness gates must be booleans")
    explanations = frozenset(explanation_surfaces)
    if not explanations <= {"memories", "bio", "icebreaker"}:
        raise ValueError("HealthKit explanation surface is not recognized")
    enabled = {
        "memories": True,
        "matching": fitness_matching_opt_in,
        "bio": bio_naming_opt_in,
        "icebreaker": icebreaker_naming_opt_in,
    }
    return tuple(
        SurfaceGrant(
            surface=surface,
            allow_selection=allowed,
            allow_naming=allowed and surface != "matching",
            allow_explanation=allowed and surface in explanations,
        )
        for surface, allowed in enabled.items()
    )


@dataclass(frozen=True, slots=True)
class SourceFact:
    """A pre-rendered, provenance-bearing fact that may support an assertion.

    ``display_text`` must already be sanitized.  Raw text is retained only so
    this boundary can reject it; renderers never return a raw fact.  Calendar
    facts marked private or future are likewise ineligible for dyadic text.
    """

    key: str
    display_text: str
    source_group: str
    surface_permissions: frozenset[str] = field(default_factory=frozenset)
    is_raw: bool = False
    is_future: bool = False
    is_private_calendar: bool = False
    surface_grants: tuple[SurfaceGrant, ...] = ()
    provider: str = "ordinary"
    policy_locked: bool = False
    data_use_purpose: str = "general_social"

    def __post_init__(self) -> None:
        for name, value in (
            ("key", self.key),
            ("display_text", self.display_text),
            ("source_group", self.source_group),
        ):
            if not isinstance(value, str) or not value.strip() or len(value) > 2048:
                raise ValueError(f"{name} must be a nonempty bounded string")
        _provider = (
            self.provider.strip().casefold()
            if isinstance(self.provider, str)
            else ""
        )
        if canonical_healthkit_source(_provider) == "healthkit":
            _provider = "healthkit"
        if not _provider or len(_provider) > 128:
            raise ValueError("source-fact provider must be a nonempty bounded string")
        if type(self.policy_locked) is not bool:
            raise ValueError("policy_locked must be a boolean")
        if self.data_use_purpose not in ALLOWED_DATA_USE_PURPOSES:
            raise ValueError("source-fact data-use purpose is not recognized")
        if _provider == "healthkit" and (
            self.policy_locked is not True
            or self.data_use_purpose != "fitness_connection"
            or self.source_group != "fitness"
        ):
            raise ValueError("HealthKit facts must retain fitness-purpose provenance")
        permissions, grants = normalize_surface_grants(
            self.surface_permissions, self.surface_grants
        )
        object.__setattr__(self, "surface_permissions", permissions)
        object.__setattr__(self, "surface_grants", grants)
        object.__setattr__(self, "provider", _provider)

    def _purpose_allows(self, surface: str, data_use_purpose: str) -> bool:
        if data_use_purpose not in ALLOWED_DATA_USE_PURPOSES:
            return False
        # Owner review is part of the source-specific service. Nonlocked facts
        # (for example, explicit self-report) may participate in either
        # purpose; policy-locked provider facts cannot be repurposed.
        return (
            surface == "memories"
            or not self.policy_locked
            or self.data_use_purpose == data_use_purpose
        )

    def permission(
        self,
        surface: str,
        use: PermissionUse | str,
        data_use_purpose: str = "general_social",
    ) -> bool:
        if not self._purpose_allows(surface, data_use_purpose):
            return False
        grant = next(
            (item for item in self.surface_grants if item.surface == surface), None
        )
        return bool(grant and grant.allows(use))

    def can_select(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        return self.permission(surface, PermissionUse.SELECT, data_use_purpose)

    def can_name(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        if not self.permission(surface, PermissionUse.NAME, data_use_purpose):
            return False
        if surface in {"bio", "icebreaker"} and (
            self.is_future or self.is_private_calendar
        ):
            return False
        return True

    def can_explain(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        if (
            not self.permission(surface, PermissionUse.EXPLAIN, data_use_purpose)
            or self.is_raw
        ):
            return False
        if surface in {"bio", "icebreaker"} and (
            self.is_future or self.is_private_calendar
        ):
            return False
        return True

    def safe_for(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        """Compatibility alias: display text is an explanation permission."""
        return self.can_explain(surface, data_use_purpose)


@dataclass(frozen=True, slots=True)
class SurfaceAssertion:
    """Typed, scored assertion used by all product surfaces.

    Parent and child concepts may coexist for editing, but ``mass`` must never
    be counted twice.  Organizers and matchers therefore select a nonredundant
    antichain before aggregation or transport.
    """

    key: str
    predicate: str
    concept_key: str
    hub_key: str
    label: str
    strength: float
    mapping_quality: float
    evidence_quality: float
    explicitness: Explicitness
    specificity: float
    information_content: float
    mass: float
    source_groups: frozenset[str]
    surface_permissions: frozenset[str]
    source_facts: tuple[SourceFact, ...] = ()
    surface_grants: tuple[SurfaceGrant, ...] = ()
    evidence_family: str | None = None

    def __post_init__(self) -> None:
        for name, value in (
            ("key", self.key),
            ("predicate", self.predicate),
            ("concept_key", self.concept_key),
            ("hub_key", self.hub_key),
            ("label", self.label),
        ):
            if not isinstance(value, str) or not value.strip() or len(value) > 1024:
                raise ValueError(f"{name} must be a nonempty bounded string")
        for name, value in (
            ("strength", self.strength),
            ("mapping_quality", self.mapping_quality),
            ("evidence_quality", self.evidence_quality),
            ("specificity", self.specificity),
            ("information_content", self.information_content),
            ("mass", self.mass),
        ):
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                or not 0.0 <= value <= 1.0
            ):
                raise ValueError(f"{name} must be finite in [0, 1]")
        if self.mass <= 0.0:
            raise ValueError("mass must be positive")
        try:
            explicitness = Explicitness(self.explicitness)
        except (TypeError, ValueError) as exc:
            raise ValueError("explicitness is not recognized") from exc
        groups = frozenset(self.source_groups)
        permissions, grants = normalize_surface_grants(
            self.surface_permissions, self.surface_grants
        )
        if any(not isinstance(group, str) or not group.strip() for group in groups):
            raise ValueError("source groups must be nonempty strings")
        facts = tuple(self.source_facts)
        if any(not isinstance(fact, SourceFact) for fact in facts):
            raise ValueError("source facts must be SourceFact instances")
        if self.evidence_family is not None and (
            not isinstance(self.evidence_family, str)
            or not self.evidence_family.strip()
            or len(self.evidence_family) > 1024
        ):
            raise ValueError("evidence family must be a nonempty bounded string")
        object.__setattr__(self, "explicitness", explicitness)
        object.__setattr__(self, "source_groups", groups)
        object.__setattr__(self, "surface_permissions", permissions)
        object.__setattr__(self, "source_facts", facts)
        object.__setattr__(self, "surface_grants", grants)

    @property
    def quality(self) -> float:
        return math.sqrt(self.mapping_quality * self.evidence_quality)

    @property
    def support(self) -> float:
        return self.strength * self.quality

    def safe_facts(
        self,
        surface: str,
        data_use_purpose: str = "general_social",
    ) -> tuple[SourceFact, ...]:
        if not self.permission(surface, PermissionUse.EXPLAIN):
            return ()
        return tuple(
            fact
            for fact in self.source_facts
            if fact.can_explain(surface, data_use_purpose)
        )

    def permission(self, surface: str, use: PermissionUse | str) -> bool:
        grant = next(
            (item for item in self.surface_grants if item.surface == surface), None
        )
        return bool(grant and grant.allows(use))

    def _policy_facts_allow(
        self,
        surface: str,
        use: PermissionUse,
        data_use_purpose: str,
    ) -> bool:
        locked = tuple(fact for fact in self.source_facts if fact.policy_locked)
        if not locked or all(
            fact.permission(surface, use, data_use_purpose) for fact in locked
        ):
            return True
        # A disallowed provider path may be omitted when a genuinely
        # independent, nonlocked fact licenses the same typed assertion.  User
        # confirmation alone is not such a path and therefore cannot launder
        # YouTube provenance.
        return any(
            not fact.policy_locked
            and fact.permission(surface, use, data_use_purpose)
            for fact in self.source_facts
        )

    def can_select(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        if not self.permission(surface, PermissionUse.SELECT):
            return False
        if surface in {"bio", "icebreaker"} and _is_future_or_scheduled_predicate(
            self.predicate
        ):
            return False
        if not self._policy_facts_allow(
            surface, PermissionUse.SELECT, data_use_purpose
        ):
            return False
        if (
            surface in {"bio", "icebreaker"}
            and self.explicitness == Explicitness.INFERRED
            and self.source_facts
        ):
            return any(
                fact.can_select(surface, data_use_purpose)
                for fact in self.source_facts
            )
        return True

    def can_name(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        if not self.can_select(surface, data_use_purpose) or not self.permission(
            surface, PermissionUse.NAME
        ):
            return False
        if not self._policy_facts_allow(
            surface, PermissionUse.NAME, data_use_purpose
        ):
            return False
        if (
            surface in {"bio", "icebreaker"}
            and self.explicitness == Explicitness.INFERRED
            and any(
                fact.provider == "healthkit" and fact.policy_locked
                for fact in self.source_facts
            )
        ):
            # A naming opt-in licenses the surface, not an unreviewed machine
            # label. HealthKit routines must also be confirmed before public
            # or dyadic wording can name them.
            return False
        if self.explicitness in {Explicitness.CONFIRMED, Explicitness.USER_ADDED}:
            return True
        if surface in {"bio", "icebreaker"}:
            return bool(self.source_facts) and any(
                fact.can_name(surface, data_use_purpose)
                for fact in self.source_facts
            )
        return True

    def can_explain(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        return (
            self.can_name(surface, data_use_purpose)
            and self.permission(surface, PermissionUse.EXPLAIN)
            and self._policy_facts_allow(
                surface, PermissionUse.EXPLAIN, data_use_purpose
            )
            and bool(self.safe_facts(surface, data_use_purpose))
        )

    def eligible_for(
        self, surface: str, data_use_purpose: str = "general_social"
    ) -> bool:
        """Compatibility alias for internal selection eligibility."""
        return self.can_select(surface, data_use_purpose)


def _is_future_or_scheduled_predicate(predicate: str) -> bool:
    normalized = predicate.casefold().replace("-", "_")
    return any(token in normalized for token in ("future", "upcoming", "scheduled"))


@dataclass(frozen=True, slots=True)
class CuratedAssociation:
    left_concept: str
    right_concept: str
    bridge_concept: str
    semantic_cost: float = 0.35

    def __post_init__(self) -> None:
        if any(
            not isinstance(value, str) or not value.strip()
            for value in (self.left_concept, self.right_concept, self.bridge_concept)
        ):
            raise ValueError("association concepts must be nonempty")
        if (
            not isinstance(self.semantic_cost, (int, float))
            or isinstance(self.semantic_cost, bool)
            or not math.isfinite(self.semantic_cost)
            or not 0.0 <= self.semantic_cost <= 1.0
        ):
            raise ValueError("association cost must be finite in [0, 1]")


@dataclass(frozen=True, slots=True)
class DyadicCost:
    total: float
    semantic: float
    relation_penalty: float
    relation_compatibility: float
    path_kind: str
    bridge_concept: str | None


DEFAULT_RELATION_COMPATIBILITY: dict[frozenset[str], float] = {
    frozenset({"likes", "explicitly_likes"}): 1.0,
    frozenset({"likes", "affinity_to"}): 0.90,
    frozenset({"explicitly_likes", "affinity_to"}): 0.90,
    frozenset({"visited", "travel_interest"}): 0.65,
    frozenset({"returns_to", "travel_interest"}): 0.70,
    frozenset({"hometown", "travel_interest"}): 0.30,
    frozenset({"lives_in", "travel_interest"}): 0.30,
    frozenset({"scheduled_travel_to", "travel_interest"}): 0.20,
}


class SemanticGraph:
    """Small graph facade used for product ranking and explanations."""

    def __init__(
        self,
        *,
        parents: Mapping[str, Iterable[str]] | None = None,
        labels: Mapping[str, str] | None = None,
        associations: Iterable[CuratedAssociation] = (),
        embedding_candidates: Mapping[tuple[str, str], float] | None = None,
        relation_compatibility: Mapping[frozenset[str], float] | None = None,
    ) -> None:
        self.parents = {
            child: frozenset(parent_values)
            for child, parent_values in (parents or {}).items()
        }
        self.labels = dict(labels or {})
        self.associations: dict[frozenset[str], CuratedAssociation] = {}
        for association in associations:
            if not isinstance(association, CuratedAssociation):
                raise ValueError("associations must be CuratedAssociation instances")
            pair = frozenset({association.left_concept, association.right_concept})
            if len(pair) != 2:
                raise ValueError("an association must connect distinct concepts")
            current = self.associations.get(pair)
            if current is None or association.semantic_cost < current.semantic_cost:
                self.associations[pair] = association
        self.embedding_candidates: dict[frozenset[str], float] = {}
        for pair, similarity in (embedding_candidates or {}).items():
            if len(pair) != 2 or pair[0] == pair[1]:
                raise ValueError("embedding candidate must connect two concepts")
            if (
                not isinstance(similarity, (int, float))
                or isinstance(similarity, bool)
                or not math.isfinite(similarity)
                or not 0.0 <= similarity <= 1.0
            ):
                raise ValueError("embedding similarity must be finite in [0, 1]")
            self.embedding_candidates[frozenset(pair)] = float(similarity)
        compatibility = dict(DEFAULT_RELATION_COMPATIBILITY)
        compatibility.update(relation_compatibility or {})
        if any(
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or not 0.0 <= value <= 1.0
            for value in compatibility.values()
        ):
            raise ValueError("relation compatibility must be finite in [0, 1]")
        self.relation_compatibility = compatibility

    def label(self, concept_key: str, fallback: str | None = None) -> str:
        return self.labels.get(concept_key, fallback or concept_key)

    def ancestor_distance(self, ancestor: str, descendant: str) -> int | None:
        if ancestor == descendant:
            return 0
        queue: deque[tuple[str, int]] = deque([(descendant, 0)])
        visited = {descendant}
        while queue:
            node, distance = queue.popleft()
            for parent in self.parents.get(node, ()):
                if parent == ancestor:
                    return distance + 1
                if parent not in visited:
                    visited.add(parent)
                    queue.append((parent, distance + 1))
        return None

    def is_ancestor(self, possible_ancestor: str, possible_descendant: str) -> bool:
        distance = self.ancestor_distance(possible_ancestor, possible_descendant)
        return distance is not None and distance > 0

    def relation_score(self, left_predicate: str, right_predicate: str) -> float:
        if left_predicate == right_predicate:
            return 1.0
        return self.relation_compatibility.get(
            frozenset({left_predicate, right_predicate}), 0.20
        )

    def cost(
        self,
        left: SurfaceAssertion,
        right: SurfaceAssertion,
        *,
        parent_child_step_cost: float = 0.18,
        embedding_candidate_penalty: float = 0.25,
        relation_weight: float = 0.40,
    ) -> DyadicCost:
        for value in (
            parent_child_step_cost,
            embedding_candidate_penalty,
            relation_weight,
        ):
            if not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ValueError("cost configuration must be finite")
        bridge: str | None = None
        if left.concept_key == right.concept_key:
            semantic = 0.0
            path_kind = "exact"
            bridge = left.concept_key
        else:
            left_is_parent = self.ancestor_distance(left.concept_key, right.concept_key)
            right_is_parent = self.ancestor_distance(right.concept_key, left.concept_key)
            if left_is_parent is not None:
                semantic = min(0.75, parent_child_step_cost * left_is_parent)
                path_kind = "parent_child"
                bridge = left.concept_key
            elif right_is_parent is not None:
                semantic = min(0.75, parent_child_step_cost * right_is_parent)
                path_kind = "parent_child"
                bridge = right.concept_key
            else:
                pair = frozenset({left.concept_key, right.concept_key})
                association = self.associations.get(pair)
                if association is not None:
                    semantic = association.semantic_cost
                    path_kind = "curated_association"
                    bridge = association.bridge_concept
                elif pair in self.embedding_candidates:
                    similarity = self.embedding_candidates[pair]
                    semantic = min(1.0, (1.0 - similarity) + embedding_candidate_penalty)
                    path_kind = "embedding_candidate"
                else:
                    semantic = 1.0
                    path_kind = "disconnected"
        compatibility = self.relation_score(left.predicate, right.predicate)
        relation_penalty = max(0.0, min(1.0, relation_weight * (1.0 - compatibility)))
        total = min(1.0, max(0.0, semantic + relation_penalty))
        return DyadicCost(
            total=total,
            semantic=semantic,
            relation_penalty=relation_penalty,
            relation_compatibility=compatibility,
            path_kind=path_kind,
            bridge_concept=bridge,
        )


def _explicitness_rank(value: Explicitness) -> int:
    return {
        Explicitness.INFERRED: 0,
        Explicitness.CONFIRMED: 1,
        Explicitness.USER_ADDED: 2,
    }[value]


def _assertion_rank(assertion: SurfaceAssertion) -> tuple[float, ...]:
    """Lexicographic rank; explicit additions win before numeric scores."""
    return (
        float(_explicitness_rank(assertion.explicitness)),
        assertion.support,
        assertion.information_content,
        assertion.specificity,
        float(len(assertion.source_groups)),
    )


def _nonredundant_antichain(
    assertions: Iterable[SurfaceAssertion],
    graph: SemanticGraph,
) -> tuple[SurfaceAssertion, ...]:
    """Select one assertion from every comparable parent/child path."""
    ranked = sorted(
        assertions,
        key=lambda item: (*_assertion_rank(item), item.label.casefold(), item.key),
        reverse=True,
    )
    selected: list[SurfaceAssertion] = []
    for candidate in ranked:
        if any(
            candidate.predicate == existing.predicate
            and candidate.hub_key == existing.hub_key
            and (
                candidate.evidence_family is None
                or existing.evidence_family is None
                or candidate.evidence_family == existing.evidence_family
            )
            and (
                graph.is_ancestor(candidate.concept_key, existing.concept_key)
                or graph.is_ancestor(existing.concept_key, candidate.concept_key)
            )
            for existing in selected
        ):
            continue
        selected.append(candidate)
    return tuple(selected)


@dataclass(frozen=True, slots=True)
class MemoriesGroup:
    hub_key: str
    summary_heading: str
    representative_children: tuple[SurfaceAssertion, ...]
    editable_assertions: tuple[SurfaceAssertion, ...]
    effective_mass: float


class MemoriesOrganizer:
    def __init__(self, graph: SemanticGraph, representative_limit: int = 3) -> None:
        if type(representative_limit) is not int or representative_limit < 1:
            raise ValueError("representative limit must be a positive integer")
        self.graph = graph
        self.representative_limit = representative_limit

    def organize(
        self,
        assertions: Iterable[SurfaceAssertion],
        *,
        suppressed_assertion_keys: Iterable[str] = (),
        suppressed_evidence_families: Iterable[str] = (),
    ) -> tuple[MemoriesGroup, ...]:
        # Suppression is exact.  It does not cascade to parents, descendants,
        # or other predicates; the feedback authority owns any wider policy.
        suppressed = frozenset(suppressed_assertion_keys)
        suppressed_families = frozenset(suppressed_evidence_families)
        by_hub: dict[str, list[SurfaceAssertion]] = defaultdict(list)
        for assertion in assertions:
            if (
                isinstance(assertion, SurfaceAssertion)
                and assertion.key not in suppressed
                and assertion.evidence_family not in suppressed_families
                and assertion.can_name("memories")
            ):
                by_hub[assertion.hub_key].append(assertion)

        groups: list[MemoriesGroup] = []
        for hub_key, items in sorted(by_hub.items()):
            editable = tuple(
                sorted(
                    items,
                    key=lambda item: (
                        *_assertion_rank(item),
                        item.label.casefold(),
                        item.key,
                    ),
                    reverse=True,
                )
            )
            nonredundant = _nonredundant_antichain(editable, self.graph)
            representatives = nonredundant[: self.representative_limit]
            summary_candidates = [
                item
                for item in editable
                if any(
                    self.graph.is_ancestor(item.concept_key, child.concept_key)
                    for child in representatives
                )
            ]
            if summary_candidates:
                heading = max(summary_candidates, key=_assertion_rank).label
            elif len(representatives) == 1 and any(
                self.graph.is_ancestor(
                    representatives[0].concept_key, item.concept_key
                )
                for item in editable
            ):
                # A favored explicit parent can itself be the nonredundant
                # representative while its inferred children remain editable.
                heading = representatives[0].label
            else:
                heading = self.graph.label(hub_key)
            groups.append(
                MemoriesGroup(
                    hub_key=hub_key,
                    summary_heading=heading,
                    representative_children=representatives,
                    editable_assertions=editable,
                    effective_mass=sum(item.mass for item in nonredundant),
                )
            )
        return tuple(groups)


@dataclass(frozen=True, slots=True)
class TransportPair:
    left_assertion_key: str
    right_assertion_key: str
    left_concept_key: str
    right_concept_key: str
    mass: float
    cost: float
    path_kind: str
    bridge_concept: str | None
    relation_compatibility: float


@dataclass(frozen=True, slots=True)
class DyadicTransportResult:
    semantic_proximity: float
    comparability: float
    transported_mass: float
    left_total_mass: float
    right_total_mass: float
    left_unmatched_mass: float
    right_unmatched_mass: float
    pairs: tuple[TransportPair, ...]
    data_use_purpose: str = "general_social"


@dataclass(frozen=True, slots=True)
class TransportConfig:
    entropy: float = 0.12
    mass_relaxation: float = 0.50
    max_pair_cost: float = 0.82
    max_iterations: int = 300
    tolerance: float = 1e-10
    minimum_pair_mass: float = 1e-9

    def __post_init__(self) -> None:
        for name, value in (
            ("entropy", self.entropy),
            ("mass_relaxation", self.mass_relaxation),
            ("max_pair_cost", self.max_pair_cost),
            ("tolerance", self.tolerance),
            ("minimum_pair_mass", self.minimum_pair_mass),
        ):
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                or value <= 0.0
            ):
                raise ValueError(f"{name} must be finite and positive")
        if self.max_pair_cost > 1.0:
            raise ValueError("max pair cost cannot exceed one")
        if type(self.max_iterations) is not int or self.max_iterations < 1:
            raise ValueError("max iterations must be a positive integer")


class DyadicMatcher:
    """Unbalanced entropy transport with explicit unmatched mass.

    The Sinkhorn iterations use KL-relaxed marginals.  A final capacity
    projection guarantees that no assertion transports more than its supplied
    mass, giving downstream code an auditable conservation invariant.
    """

    def __init__(
        self,
        graph: SemanticGraph,
        config: TransportConfig | None = None,
    ) -> None:
        self.graph = graph
        self.config = config or TransportConfig()

    @staticmethod
    def _safe_exp(value: float) -> float:
        # Two scaling vectors are multiplied when the plan is materialized.
        # Limiting each to exp(350), rather than the scalar exp(700) limit,
        # keeps their product finite as well.
        return math.exp(max(-350.0, min(350.0, value)))

    def match(
        self,
        left_assertions: Iterable[SurfaceAssertion],
        right_assertions: Iterable[SurfaceAssertion],
        *,
        surface: str = "matching",
        expected_source_groups: Iterable[str] = (),
        data_use_purpose: str = "general_social",
    ) -> DyadicTransportResult:
        if surface not in ALLOWED_SURFACES:
            raise ValueError("matching surface is not recognized")
        if data_use_purpose not in ALLOWED_DATA_USE_PURPOSES:
            raise ValueError("matching data-use purpose is not recognized")
        left = _nonredundant_antichain(
            (
                item
                for item in left_assertions
                if item.eligible_for(surface, data_use_purpose)
            ),
            self.graph,
        )
        right = _nonredundant_antichain(
            (
                item
                for item in right_assertions
                if item.eligible_for(surface, data_use_purpose)
            ),
            self.graph,
        )
        left_total = sum(item.mass for item in left)
        right_total = sum(item.mass for item in right)
        if not left or not right or left_total <= 0.0 or right_total <= 0.0:
            return DyadicTransportResult(
                semantic_proximity=0.0,
                comparability=0.0,
                transported_mass=0.0,
                left_total_mass=left_total,
                right_total_mass=right_total,
                left_unmatched_mass=left_total,
                right_unmatched_mass=right_total,
                pairs=(),
                data_use_purpose=data_use_purpose,
            )

        cost_meta = [[self.graph.cost(a, b) for b in right] for a in left]
        kernel: list[list[float]] = []
        for row in cost_meta:
            kernel.append(
                [
                    self._safe_exp(-entry.total / self.config.entropy)
                    if entry.total <= self.config.max_pair_cost
                    else 0.0
                    for entry in row
                ]
            )
        a = [item.mass for item in left]
        b = [item.mass for item in right]
        u = [1.0] * len(left)
        v = [1.0] * len(right)
        tau = self.config.mass_relaxation / (
            self.config.mass_relaxation + self.config.entropy
        )
        floor = 1e-300

        for _ in range(self.config.max_iterations):
            previous_u = tuple(u)
            previous_v = tuple(v)
            for i in range(len(left)):
                denominator = sum(kernel[i][j] * v[j] for j in range(len(right)))
                u[i] = (
                    0.0
                    if denominator <= floor
                    else self._safe_exp(tau * (math.log(a[i]) - math.log(denominator)))
                )
            for j in range(len(right)):
                denominator = sum(kernel[i][j] * u[i] for i in range(len(left)))
                v[j] = (
                    0.0
                    if denominator <= floor
                    else self._safe_exp(tau * (math.log(b[j]) - math.log(denominator)))
                )
            change = max(
                [abs(u[i] - previous_u[i]) / max(1.0, abs(previous_u[i])) for i in range(len(u))]
                + [abs(v[j] - previous_v[j]) / max(1.0, abs(previous_v[j])) for j in range(len(v))]
            )
            if change <= self.config.tolerance:
                break

        plan = [
            [u[i] * kernel[i][j] * v[j] for j in range(len(right))]
            for i in range(len(left))
        ]
        # Iterative down-scaling is a capacity projection.  It cannot create
        # mass and therefore remains safe even if Sinkhorn stopped early.
        for _ in range(20):
            changed = False
            for i, capacity in enumerate(a):
                row_sum = sum(plan[i])
                if row_sum > capacity * (1.0 + 1e-12):
                    scale = capacity / row_sum
                    plan[i] = [value * scale for value in plan[i]]
                    changed = True
            for j, capacity in enumerate(b):
                column_sum = sum(plan[i][j] for i in range(len(left)))
                if column_sum > capacity * (1.0 + 1e-12):
                    scale = capacity / column_sum
                    for i in range(len(left)):
                        plan[i][j] *= scale
                    changed = True
            if not changed:
                break

        pairs: list[TransportPair] = []
        for i, left_item in enumerate(left):
            for j, right_item in enumerate(right):
                mass = plan[i][j]
                if mass < self.config.minimum_pair_mass:
                    continue
                meta = cost_meta[i][j]
                pairs.append(
                    TransportPair(
                        left_assertion_key=left_item.key,
                        right_assertion_key=right_item.key,
                        left_concept_key=left_item.concept_key,
                        right_concept_key=right_item.concept_key,
                        mass=mass,
                        cost=meta.total,
                        path_kind=meta.path_kind,
                        bridge_concept=meta.bridge_concept,
                        relation_compatibility=meta.relation_compatibility,
                    )
                )
        pairs.sort(key=lambda item: (item.mass * (1.0 - item.cost), item.mass), reverse=True)
        transported = sum(item.mass for item in pairs)
        proximity = (
            sum(item.mass * (1.0 - item.cost) for item in pairs) / transported
            if transported > 0.0
            else 0.0
        )

        observed_left = frozenset().union(*(item.source_groups for item in left))
        observed_right = frozenset().union(*(item.source_groups for item in right))
        expected = frozenset(expected_source_groups) or observed_left | observed_right
        if expected:
            left_source_coverage = len(observed_left & expected) / len(expected)
            right_source_coverage = len(observed_right & expected) / len(expected)
            source_comparability = math.sqrt(
                left_source_coverage * right_source_coverage
            )
        else:
            source_comparability = 1.0
        mass_comparability = (
            min(1.0, 2.0 * transported / (left_total + right_total))
            if left_total + right_total > 0.0
            else 0.0
        )
        comparability = source_comparability * mass_comparability
        return DyadicTransportResult(
            semantic_proximity=min(1.0, max(0.0, proximity)),
            comparability=min(1.0, max(0.0, comparability)),
            transported_mass=transported,
            left_total_mass=left_total,
            right_total_mass=right_total,
            left_unmatched_mass=max(0.0, left_total - transported),
            right_unmatched_mass=max(0.0, right_total - transported),
            pairs=tuple(pairs),
            data_use_purpose=data_use_purpose,
        )


@dataclass(frozen=True, slots=True)
class BioFact:
    assertion_key: str
    predicate: str
    concept_key: str
    display_text: str
    stable: bool


@dataclass(frozen=True, slots=True)
class DirectionalBioSelection:
    stable_facts: tuple[BioFact, ...]
    viewer_conditioned_fact: BioFact | None

    @property
    def all_facts(self) -> tuple[BioFact, ...]:
        return self.stable_facts + (
            (self.viewer_conditioned_fact,) if self.viewer_conditioned_fact else ()
        )


class DirectionalBioSelector:
    """Choose subject facts; the viewer may influence at most one clause."""

    def __init__(
        self,
        graph: SemanticGraph,
        *,
        stable_clause_count: int = 2,
        minimum_information_content: float = 0.30,
    ) -> None:
        if type(stable_clause_count) is not int or stable_clause_count < 1:
            raise ValueError("at least one stable bio clause is required")
        if (
            not isinstance(minimum_information_content, (int, float))
            or not math.isfinite(minimum_information_content)
            or not 0.0 <= minimum_information_content <= 1.0
        ):
            raise ValueError("minimum information content must be in [0, 1]")
        self.graph = graph
        self.stable_clause_count = stable_clause_count
        self.minimum_information_content = minimum_information_content

    @staticmethod
    def _display_text(
        assertion: SurfaceAssertion,
        data_use_purpose: str = "general_social",
    ) -> str:
        safe = assertion.safe_facts("bio", data_use_purpose)
        return safe[0].display_text if safe else assertion.label

    def select(
        self,
        viewer_assertions: Iterable[SurfaceAssertion],
        subject_assertions: Iterable[SurfaceAssertion],
        transport: DyadicTransportResult,
        *,
        data_use_purpose: str = "general_social",
    ) -> DirectionalBioSelection:
        if data_use_purpose not in ALLOWED_DATA_USE_PURPOSES:
            raise ValueError("bio data-use purpose is not recognized")
        del viewer_assertions  # transport already freezes the viewer comparison
        subject = {
            item.key: item
            for item in _nonredundant_antichain(
                (
                    item
                    for item in subject_assertions
                    if item.can_name("bio", data_use_purpose)
                    and item.information_content >= self.minimum_information_content
                ),
                self.graph,
            )
        }
        ranked_subject = sorted(
            subject.values(),
            key=lambda item: (*_assertion_rank(item), item.key),
            reverse=True,
        )
        stable_items = ranked_subject[: self.stable_clause_count]
        stable_keys = {item.key for item in stable_items}
        stable_facts = tuple(
            BioFact(
                assertion_key=item.key,
                predicate=item.predicate,
                concept_key=item.concept_key,
                display_text=self._display_text(item, data_use_purpose),
                stable=True,
            )
            for item in stable_items
        )

        resonant: list[tuple[float, SurfaceAssertion]] = []
        for pair in transport.pairs:
            item = subject.get(pair.right_assertion_key)
            if item is None or item.key in stable_keys:
                continue
            utility = (
                pair.mass
                * (1.0 - pair.cost)
                * item.support
                * item.information_content
            )
            resonant.append((utility, item))
        if not resonant:
            viewer_fact = None
        else:
            _, selected = max(resonant, key=lambda pair: (pair[0], *_assertion_rank(pair[1])))
            viewer_fact = BioFact(
                assertion_key=selected.key,
                predicate=selected.predicate,
                concept_key=selected.concept_key,
                display_text=self._display_text(selected, data_use_purpose),
                stable=False,
            )
        return DirectionalBioSelection(
            stable_facts=stable_facts,
            viewer_conditioned_fact=viewer_fact,
        )


class WordingLicense(StrEnum):
    BOTH_LIKE = "both_like"
    SHARED_THREAD = "shared_thread"
    CONVERSATION_TOPIC = "conversation_topic"


@dataclass(frozen=True, slots=True)
class Icebreaker:
    bridge_concept: str
    bridge_label: str
    score: float
    wording_license: WordingLicense
    headline: str
    left_fact: str
    right_fact: str
    left_assertion_key: str
    right_assertion_key: str
    data_use_purpose: str = "general_social"


LIKE_PREDICATES = frozenset({"likes", "explicitly_likes", "affinity_to"})


class IcebreakerGenerator:
    def __init__(
        self,
        graph: SemanticGraph,
        *,
        minimum_information_content: float = 0.20,
        maximum_pair_cost: float = 0.75,
    ) -> None:
        for value in (minimum_information_content, maximum_pair_cost):
            if (
                not isinstance(value, (int, float))
                or not math.isfinite(value)
                or not 0.0 <= value <= 1.0
            ):
                raise ValueError("icebreaker thresholds must be in [0, 1]")
        self.graph = graph
        self.minimum_information_content = minimum_information_content
        self.maximum_pair_cost = maximum_pair_cost

    @staticmethod
    def _harmonic(left: float, right: float) -> float:
        return 0.0 if left <= 0.0 or right <= 0.0 else 2.0 * left * right / (left + right)

    @staticmethod
    def _predicate_fact(
        assertion: SurfaceAssertion,
        *,
        person: str,
        second_person: bool,
        data_use_purpose: str = "general_social",
    ) -> str:
        safe = assertion.safe_facts("icebreaker", data_use_purpose)
        if safe:
            return safe[0].display_text
        subject = "You" if second_person else person
        predicate = assertion.predicate
        if predicate in LIKE_PREDICATES:
            return f"{subject} like{'s' if not second_person else ''} {assertion.label}"
        if predicate == "visited":
            return f"{subject} {'have' if second_person else 'has'} traveled to {assertion.label}"
        if predicate == "returns_to":
            return f"{subject} often return{'s' if not second_person else ''} to {assertion.label}"
        if predicate == "hometown":
            return f"{assertion.label} is home for {subject.lower() if second_person else subject}"
        return f"{assertion.label} comes up in {subject.lower() if second_person else subject + chr(39) + 's'} profile"

    @staticmethod
    def _license(
        left: SurfaceAssertion,
        right: SurfaceAssertion,
        cost: DyadicCost,
    ) -> WordingLicense:
        both_explicit = all(
            item.explicitness in {Explicitness.CONFIRMED, Explicitness.USER_ADDED}
            for item in (left, right)
        )
        if (
            left.predicate in LIKE_PREDICATES
            and right.predicate in LIKE_PREDICATES
            and both_explicit
            and cost.relation_compatibility >= 0.85
            and min(left.support, right.support) >= 0.55
        ):
            return WordingLicense.BOTH_LIKE
        if (
            min(left.support, right.support) >= 0.40
            and cost.relation_compatibility >= 0.45
            and cost.path_kind != "embedding_candidate"
        ):
            return WordingLicense.SHARED_THREAD
        return WordingLicense.CONVERSATION_TOPIC

    def generate(
        self,
        left_assertions: Iterable[SurfaceAssertion],
        right_assertions: Iterable[SurfaceAssertion],
        *,
        right_person_name: str,
        data_use_purpose: str = "general_social",
    ) -> Icebreaker | None:
        if not isinstance(right_person_name, str) or not right_person_name.strip():
            raise ValueError("right person name is required")
        if data_use_purpose not in ALLOWED_DATA_USE_PURPOSES:
            raise ValueError("icebreaker data-use purpose is not recognized")
        left = _nonredundant_antichain(
            (
                item
                for item in left_assertions
                if item.can_name("icebreaker", data_use_purpose)
                and item.information_content >= self.minimum_information_content
            ),
            self.graph,
        )
        right = _nonredundant_antichain(
            (
                item
                for item in right_assertions
                if item.can_name("icebreaker", data_use_purpose)
                and item.information_content >= self.minimum_information_content
            ),
            self.graph,
        )
        candidates: list[
            tuple[float, float, float, SurfaceAssertion, SurfaceAssertion, DyadicCost]
        ] = []
        for left_item in left:
            for right_item in right:
                cost = self.graph.cost(left_item, right_item)
                if cost.bridge_concept is None or cost.total > self.maximum_pair_cost:
                    continue
                harmonic_support = self._harmonic(left_item.support, right_item.support)
                specificity = math.sqrt(left_item.specificity * right_item.specificity)
                information = min(
                    left_item.information_content, right_item.information_content
                )
                quality = math.sqrt(left_item.quality * right_item.quality)
                score = (
                    harmonic_support
                    * (0.60 * specificity + 0.40 * information)
                    * quality
                    * cost.relation_compatibility
                    * (1.0 - cost.semantic)
                )
                candidates.append(
                    (score, information, specificity, left_item, right_item, cost)
                )
        if not candidates:
            return None
        score, _, _, left_item, right_item, cost = max(
            candidates,
            key=lambda item: (
                item[0],
                item[1],
                item[2],
                item[3].concept_key,
                item[4].concept_key,
            ),
        )
        assert cost.bridge_concept is not None
        bridge_label = self.graph.label(
            cost.bridge_concept,
            left_item.label if left_item.concept_key == cost.bridge_concept else None,
        )
        license_name = self._license(left_item, right_item, cost)
        headline = {
            WordingLicense.BOTH_LIKE: f"You both like {bridge_label}.",
            WordingLicense.SHARED_THREAD: f"{bridge_label} looks like a shared thread.",
            WordingLicense.CONVERSATION_TOPIC: (
                f"{bridge_label} could be a conversation topic."
            ),
        }[license_name]
        return Icebreaker(
            bridge_concept=cost.bridge_concept,
            bridge_label=bridge_label,
            score=score,
            wording_license=license_name,
            headline=headline,
            left_fact=self._predicate_fact(
                left_item,
                person="You",
                second_person=True,
                data_use_purpose=data_use_purpose,
            ),
            right_fact=self._predicate_fact(
                right_item,
                person=right_person_name.strip(),
                second_person=False,
                data_use_purpose=data_use_purpose,
            ),
            left_assertion_key=left_item.key,
            right_assertion_key=right_item.key,
            data_use_purpose=data_use_purpose,
        )


__all__ = [
    "ALLOWED_DATA_USE_PURPOSES",
    "ALLOWED_SURFACES",
    "BioFact",
    "CuratedAssociation",
    "DirectionalBioSelection",
    "DirectionalBioSelector",
    "DyadicCost",
    "DyadicMatcher",
    "DyadicTransportResult",
    "Explicitness",
    "Icebreaker",
    "IcebreakerGenerator",
    "MemoriesGroup",
    "MemoriesOrganizer",
    "PermissionUse",
    "SemanticGraph",
    "SourceFact",
    "SurfaceGrant",
    "SurfaceAssertion",
    "TransportConfig",
    "TransportPair",
    "WordingLicense",
    "normalize_surface_grants",
    "youtube_policy_surface_grants",
    "healthkit_fitness_surface_grants",
]
