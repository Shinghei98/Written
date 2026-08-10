"""Multiresolution contract for explicit user additions.

This module separates four facts that are often incorrectly collapsed:

* the exact phrase the user chose;
* certainty that the user intentionally selected it;
* confidence in a proposed canonical ontology mapping; and
* attenuated ancestor views used at broader display resolutions.

Suggestion candidates never mutate an addition.  A separate, explicit accept
operation is required before a canonical concept can be attached.  Likewise,
one-tap removal is a surface suppression for one evidence family; it is not a
semantic negative label.
"""

from __future__ import annotations

import math
from collections import defaultdict, deque
from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Iterable, Mapping

from .surfaces import (
    Explicitness,
    PermissionUse,
    SourceFact,
    SurfaceAssertion,
    SurfaceGrant,
    normalize_surface_grants,
)


ALLOWED_ADDITION_SURFACES = frozenset(
    {"memories", "matching", "bio", "icebreaker"}
)


class AdditionMode(StrEnum):
    CANONICAL_SELECTION = "canonical_selection"
    FREE_TEXT = "free_text"


class AdditionRelation(StrEnum):
    EXPLICIT_ASSOCIATION_WITH = "explicit_association_with"
    LIKES = "likes"
    HOMETOWN = "hometown"
    VISITED = "visited"
    TRAVEL_INTEREST = "travel_interest"
    WANTS_TO_VISIT = "wants_to_visit"
    RETURNS_TO = "returns_to"
    LIVES_IN = "lives_in"


class AssertionOrigin(StrEnum):
    USER_ADDED = "user_added"
    CONFIRMED = "confirmed"
    INFERRED = "inferred"


class SuggestionKind(StrEnum):
    CANONICAL = "canonical"
    PARENT = "parent"


EXPLICIT_ONLY_RELATIONS = frozenset(
    {AdditionRelation.HOMETOWN, AdditionRelation.LIVES_IN}
)


def relation_allowed_for_origin(
    relation: AdditionRelation | str,
    origin: AssertionOrigin | str,
) -> bool:
    """Return whether an origin may license the requested predicate."""
    try:
        normalized_relation = AdditionRelation(relation)
        normalized_origin = AssertionOrigin(origin)
    except (TypeError, ValueError):
        return False
    if normalized_relation in EXPLICIT_ONLY_RELATIONS:
        return normalized_origin == AssertionOrigin.USER_ADDED
    return True


def _bounded_unit(name: str, value: float, *, positive: bool = False) -> None:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
        or not 0.0 <= value <= 1.0
        or (positive and value <= 0.0)
    ):
        qualifier = "positive and " if positive else ""
        raise ValueError(f"{name} must be {qualifier}finite in [0, 1]")


def _bounded_text(name: str, value: str, limit: int = 2048) -> None:
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(f"{name} must be a nonempty bounded string")


@dataclass(frozen=True, slots=True)
class SuggestionCandidate:
    concept_key: str
    label: str
    kind: SuggestionKind
    canonical_mapping_confidence: float
    method: str

    def __post_init__(self) -> None:
        for name, value in (
            ("concept_key", self.concept_key),
            ("label", self.label),
            ("method", self.method),
        ):
            _bounded_text(name, value, 1024)
        try:
            kind = SuggestionKind(self.kind)
        except (TypeError, ValueError) as exc:
            raise ValueError("suggestion kind is not recognized") from exc
        _bounded_unit(
            "canonical_mapping_confidence", self.canonical_mapping_confidence
        )
        object.__setattr__(self, "kind", kind)


@dataclass(frozen=True, slots=True)
class UserAddedTerm:
    addition_id: str
    exact_phrase: str
    concept_kind: str
    relation: AdditionRelation
    mode: AdditionMode
    explicitness: float
    selection_confidence: float
    canonical_mapping_confidence: float
    canonical_concept_key: str | None
    canonical_label: str | None
    evidence_family: str
    mass: float
    surface_permissions: frozenset[str]
    linked_observation_ids: tuple[str, ...] = ()
    suggestions: tuple[SuggestionCandidate, ...] = ()
    surface_grants: tuple[SurfaceGrant, ...] = ()

    def __post_init__(self) -> None:
        for name, value in (
            ("addition_id", self.addition_id),
            ("exact_phrase", self.exact_phrase),
            ("concept_kind", self.concept_kind),
            ("evidence_family", self.evidence_family),
        ):
            _bounded_text(name, value)
        try:
            relation = AdditionRelation(self.relation)
            mode = AdditionMode(self.mode)
        except (TypeError, ValueError) as exc:
            raise ValueError("addition mode or relation is not recognized") from exc
        for name, value in (
            ("explicitness", self.explicitness),
            ("selection_confidence", self.selection_confidence),
            ("canonical_mapping_confidence", self.canonical_mapping_confidence),
            ("mass", self.mass),
        ):
            _bounded_unit(name, value, positive=name == "mass")
        permissions, grants = normalize_surface_grants(
            self.surface_permissions, self.surface_grants
        )
        linked = tuple(dict.fromkeys(self.linked_observation_ids))
        if any(
            not isinstance(identifier, str)
            or not identifier.strip()
            or len(identifier) > 1024
            for identifier in linked
        ):
            raise ValueError("linked observation IDs must be nonempty bounded strings")
        suggestions = tuple(self.suggestions)
        if any(not isinstance(item, SuggestionCandidate) for item in suggestions):
            raise ValueError("suggestions must be SuggestionCandidate instances")
        if mode == AdditionMode.CANONICAL_SELECTION:
            if not self.canonical_concept_key or not self.canonical_label:
                raise ValueError("canonical selection requires a concept key and label")
            _bounded_text("canonical_concept_key", self.canonical_concept_key, 1024)
            _bounded_text("canonical_label", self.canonical_label, 1024)
        elif self.canonical_concept_key is not None or self.canonical_label is not None:
            raise ValueError("free text cannot be silently assigned a canonical concept")
        if not relation_allowed_for_origin(relation, AssertionOrigin.USER_ADDED):
            raise ValueError("relation cannot be created by a user addition")
        object.__setattr__(self, "relation", relation)
        object.__setattr__(self, "mode", mode)
        object.__setattr__(self, "surface_permissions", permissions)
        object.__setattr__(self, "surface_grants", grants)
        object.__setattr__(self, "linked_observation_ids", linked)
        object.__setattr__(self, "suggestions", suggestions)

    def permission(self, surface: str, use: PermissionUse | str) -> bool:
        grant = next(
            (item for item in self.surface_grants if item.surface == surface), None
        )
        return bool(grant and grant.allows(use))


def _coerce_relation(
    relation: AdditionRelation | str | None,
    *,
    concept_kind: str,
) -> AdditionRelation:
    if relation is None:
        # A bare place establishes only that the user chose to associate the
        # phrase with themselves; it does not mean hometown, visited, or liked.
        return AdditionRelation.EXPLICIT_ASSOCIATION_WITH
    try:
        return AdditionRelation(relation)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"unsupported relation for {concept_kind}") from exc


def create_canonical_addition(
    *,
    addition_id: str,
    exact_phrase: str,
    concept_kind: str,
    canonical_concept_key: str,
    canonical_label: str,
    relation: AdditionRelation | str | None = None,
    selection_confidence: float = 1.0,
    canonical_mapping_confidence: float = 1.0,
    mass: float = 1.0,
    surface_permissions: Iterable[str] = ("memories",),
    surface_grants: Iterable[SurfaceGrant] = (),
    linked_observation_ids: Iterable[str] = (),
    evidence_family: str | None = None,
) -> UserAddedTerm:
    """Create an explicit addition after a user selects a canonical result."""
    family = evidence_family or f"user_addition:{addition_id}"
    return UserAddedTerm(
        addition_id=addition_id,
        exact_phrase=exact_phrase,
        concept_kind=concept_kind,
        relation=_coerce_relation(relation, concept_kind=concept_kind),
        mode=AdditionMode.CANONICAL_SELECTION,
        explicitness=1.0,
        selection_confidence=selection_confidence,
        canonical_mapping_confidence=canonical_mapping_confidence,
        canonical_concept_key=canonical_concept_key,
        canonical_label=canonical_label,
        evidence_family=family,
        mass=mass,
        surface_permissions=frozenset(surface_permissions),
        surface_grants=tuple(surface_grants),
        linked_observation_ids=tuple(linked_observation_ids),
    )


def create_free_text_addition(
    *,
    addition_id: str,
    exact_phrase: str,
    concept_kind: str,
    relation: AdditionRelation | str | None = None,
    selection_confidence: float = 1.0,
    mass: float = 1.0,
    surface_permissions: Iterable[str] = ("memories",),
    surface_grants: Iterable[SurfaceGrant] = (),
    linked_observation_ids: Iterable[str] = (),
    suggestions: Iterable[SuggestionCandidate] = (),
    evidence_family: str | None = None,
) -> UserAddedTerm:
    """Create a local exact term; suggestions remain unaccepted candidates."""
    family = evidence_family or f"user_addition:{addition_id}"
    return UserAddedTerm(
        addition_id=addition_id,
        exact_phrase=exact_phrase,
        concept_kind=concept_kind,
        relation=_coerce_relation(relation, concept_kind=concept_kind),
        mode=AdditionMode.FREE_TEXT,
        explicitness=1.0,
        selection_confidence=selection_confidence,
        canonical_mapping_confidence=0.0,
        canonical_concept_key=None,
        canonical_label=None,
        evidence_family=family,
        mass=mass,
        surface_permissions=frozenset(surface_permissions),
        surface_grants=tuple(surface_grants),
        linked_observation_ids=tuple(linked_observation_ids),
        suggestions=tuple(suggestions),
    )


def attach_suggestions(
    addition: UserAddedTerm,
    suggestions: Iterable[SuggestionCandidate],
) -> UserAddedTerm:
    """Return a copy containing candidates without changing its mapping."""
    if not isinstance(addition, UserAddedTerm):
        raise ValueError("addition must be a UserAddedTerm")
    proposed = tuple(suggestions)
    if any(not isinstance(item, SuggestionCandidate) for item in proposed):
        raise ValueError("suggestions must be SuggestionCandidate instances")
    return replace(addition, suggestions=proposed)


def accept_suggestion(
    addition: UserAddedTerm,
    concept_key: str,
    *,
    selection_confidence: float = 1.0,
) -> UserAddedTerm:
    """Explicitly accept one suggestion while preserving ``exact_phrase``."""
    if not isinstance(addition, UserAddedTerm):
        raise ValueError("addition must be a UserAddedTerm")
    matches = [item for item in addition.suggestions if item.concept_key == concept_key]
    if len(matches) != 1:
        raise ValueError("suggestion must resolve to exactly one attached candidate")
    selected = matches[0]
    return UserAddedTerm(
        addition_id=addition.addition_id,
        exact_phrase=addition.exact_phrase,
        concept_kind=addition.concept_kind,
        relation=addition.relation,
        mode=AdditionMode.CANONICAL_SELECTION,
        explicitness=addition.explicitness,
        selection_confidence=selection_confidence,
        canonical_mapping_confidence=selected.canonical_mapping_confidence,
        canonical_concept_key=selected.concept_key,
        canonical_label=selected.label,
        evidence_family=addition.evidence_family,
        mass=addition.mass,
        surface_permissions=addition.surface_permissions,
        surface_grants=addition.surface_grants,
        linked_observation_ids=addition.linked_observation_ids,
        suggestions=addition.suggestions,
    )


class ConceptHierarchy:
    """Upward-only view of a curated concept DAG."""

    def __init__(
        self,
        *,
        parents: Mapping[str, Iterable[str]],
        labels: Mapping[str, str] | None = None,
    ) -> None:
        self.parents: dict[str, frozenset[str]] = {}
        for child, parent_values in parents.items():
            _bounded_text("child concept", child, 1024)
            normalized = frozenset(parent_values)
            if any(
                not isinstance(parent, str) or not parent.strip() or len(parent) > 1024
                for parent in normalized
            ):
                raise ValueError("parent concepts must be nonempty bounded strings")
            if child in normalized:
                raise ValueError("concept cannot be its own direct parent")
            self.parents[child] = normalized
        self.labels = dict(labels or {})

    def label(self, concept_key: str) -> str:
        return self.labels.get(concept_key, concept_key)

    def ancestor_depths(self, concept_key: str) -> dict[str, int]:
        """Return shortest upward depth; descendants are never traversed."""
        depths: dict[str, int] = {concept_key: 0}
        queue: deque[str] = deque([concept_key])
        while queue:
            child = queue.popleft()
            child_depth = depths[child]
            for parent in self.parents.get(child, ()):
                proposed = child_depth + 1
                previous = depths.get(parent)
                if previous is None or proposed < previous:
                    depths[parent] = proposed
                    queue.append(parent)
        return depths


@dataclass(frozen=True, slots=True)
class ResolutionAssertion:
    key: str
    origin_addition_id: str
    exact_phrase: str
    relation: AdditionRelation
    concept_key: str | None
    label: str
    depth: int
    is_primary: bool
    explicitness: float
    selection_confidence: float
    canonical_mapping_confidence: float
    propagation_weight: float
    mass: float
    evidence_family: str
    surface_permissions: frozenset[str]
    linked_observation_ids: tuple[str, ...]
    surface_grants: tuple[SurfaceGrant, ...] = ()

    def __post_init__(self) -> None:
        for name, value in (
            ("key", self.key),
            ("origin_addition_id", self.origin_addition_id),
            ("exact_phrase", self.exact_phrase),
            ("label", self.label),
            ("evidence_family", self.evidence_family),
        ):
            _bounded_text(name, value)
        if type(self.depth) is not int or self.depth < 0:
            raise ValueError("resolution depth must be a nonnegative integer")
        for name, value in (
            ("explicitness", self.explicitness),
            ("selection_confidence", self.selection_confidence),
            ("canonical_mapping_confidence", self.canonical_mapping_confidence),
            ("propagation_weight", self.propagation_weight),
            ("mass", self.mass),
        ):
            _bounded_unit(name, value, positive=name == "mass")
        if self.is_primary != (self.depth == 0):
            raise ValueError("only depth-zero assertion may be primary")
        permissions, grants = normalize_surface_grants(
            self.surface_permissions, self.surface_grants
        )
        object.__setattr__(self, "surface_permissions", permissions)
        object.__setattr__(self, "surface_grants", grants)

    def permission(self, surface: str, use: PermissionUse | str) -> bool:
        grant = next(
            (item for item in self.surface_grants if item.surface == surface), None
        )
        return bool(grant and grant.allows(use))


def build_resolution_assertions(
    addition: UserAddedTerm,
    hierarchy: ConceptHierarchy,
    *,
    attenuation: float = 0.60,
) -> tuple[ResolutionAssertion, ...]:
    """Build upward resolution views while conserving evidence-family mass.

    Total raw weight at each depth is ``attenuation ** depth`` and is split
    equally among DAG nodes at that depth.  The weights are normalized so the
    returned masses sum exactly to the addition's mass.  Thus branching and
    multiple resolutions cannot manufacture extra votes.
    """
    if not isinstance(addition, UserAddedTerm) or not isinstance(
        hierarchy, ConceptHierarchy
    ):
        raise ValueError("valid addition and hierarchy are required")
    _bounded_unit("attenuation", attenuation, positive=True)
    if addition.mode == AdditionMode.FREE_TEXT:
        return (
            ResolutionAssertion(
                key=f"{addition.addition_id}:local",
                origin_addition_id=addition.addition_id,
                exact_phrase=addition.exact_phrase,
                relation=addition.relation,
                concept_key=None,
                label=addition.exact_phrase,
                depth=0,
                is_primary=True,
                explicitness=addition.explicitness,
                selection_confidence=addition.selection_confidence,
                canonical_mapping_confidence=0.0,
                propagation_weight=1.0,
                mass=addition.mass,
                evidence_family=addition.evidence_family,
                surface_permissions=addition.surface_permissions,
                linked_observation_ids=addition.linked_observation_ids,
                surface_grants=addition.surface_grants,
            ),
        )

    assert addition.canonical_concept_key is not None
    depths = hierarchy.ancestor_depths(addition.canonical_concept_key)
    by_depth: dict[int, list[str]] = defaultdict(list)
    for concept_key, depth in depths.items():
        by_depth[depth].append(concept_key)
    raw_weights: dict[str, float] = {}
    for depth, concepts in by_depth.items():
        level_weight = attenuation**depth
        for concept_key in concepts:
            raw_weights[concept_key] = level_weight / len(concepts)
    normalizer = sum(raw_weights.values())
    assertions: list[ResolutionAssertion] = []
    for concept_key, depth in sorted(
        depths.items(), key=lambda item: (item[1], item[0])
    ):
        is_primary = depth == 0
        assertions.append(
            ResolutionAssertion(
                key=f"{addition.addition_id}:{concept_key}:d{depth}",
                origin_addition_id=addition.addition_id,
                exact_phrase=addition.exact_phrase,
                relation=addition.relation,
                concept_key=concept_key,
                label=(
                    addition.exact_phrase
                    if is_primary
                    else hierarchy.label(concept_key)
                ),
                depth=depth,
                is_primary=is_primary,
                explicitness=addition.explicitness,
                selection_confidence=addition.selection_confidence,
                canonical_mapping_confidence=(
                    addition.canonical_mapping_confidence * attenuation**depth
                ),
                propagation_weight=attenuation**depth,
                mass=addition.mass * raw_weights[concept_key] / normalizer,
                evidence_family=addition.evidence_family,
                surface_permissions=addition.surface_permissions,
                linked_observation_ids=addition.linked_observation_ids,
                surface_grants=addition.surface_grants,
            )
        )
    return tuple(assertions)


def project_resolution_to_surface(
    assertion: ResolutionAssertion,
    *,
    hub_key: str,
    specificity: float,
    information_content: float,
    source_groups: Iterable[str] = ("user_added",),
    source_facts: Iterable[SourceFact] = (),
) -> SurfaceAssertion:
    """Project one addition view into the shared product-surface contract.

    The evidence-family mass and all granular permissions are preserved.  A
    free-text primary view receives a stable local concept ID; it is not
    represented as a canonical ontology mapping.
    """
    if not isinstance(assertion, ResolutionAssertion):
        raise ValueError("assertion must be a ResolutionAssertion")
    _bounded_text("hub_key", hub_key, 1024)
    _bounded_unit("specificity", specificity)
    _bounded_unit("information_content", information_content)
    facts = tuple(source_facts)
    if any(not isinstance(item, SourceFact) for item in facts):
        raise ValueError("source facts must be SourceFact instances")
    concept_key = assertion.concept_key or f"user_term:{assertion.origin_addition_id}"
    mapping_quality = (
        assertion.canonical_mapping_confidence
        if assertion.concept_key is not None
        else 1.0
    )
    return SurfaceAssertion(
        key=assertion.key,
        predicate=assertion.relation.value,
        concept_key=concept_key,
        hub_key=hub_key,
        label=assertion.label,
        strength=min(
            1.0, assertion.selection_confidence * assertion.propagation_weight
        ),
        mapping_quality=mapping_quality,
        evidence_quality=1.0,
        explicitness=Explicitness.USER_ADDED,
        specificity=specificity,
        information_content=information_content,
        mass=assertion.mass,
        source_groups=frozenset(source_groups),
        surface_permissions=assertion.surface_permissions,
        source_facts=facts,
        surface_grants=assertion.surface_grants,
        evidence_family=assertion.evidence_family,
    )


@dataclass(frozen=True, slots=True)
class MappingPositiveLabel:
    observation_id: str
    concept_key: str
    evidence_family: str
    exact_phrase: str


@dataclass(frozen=True, slots=True)
class AdditionLearningEffects:
    user_affinity_positive: bool
    surfacing_positive: bool
    mapping_positive_labels: tuple[MappingPositiveLabel, ...]
    semantic_global_negative: bool = False


def learning_effects(
    addition: UserAddedTerm,
    *,
    validated_linked_observation_ids: Iterable[str] = (),
) -> AdditionLearningEffects:
    """Create mapping labels only for server-validated, explicitly linked rows."""
    if not isinstance(addition, UserAddedTerm):
        raise ValueError("addition must be a UserAddedTerm")
    validated = frozenset(validated_linked_observation_ids)
    requested = frozenset(addition.linked_observation_ids)
    if not validated <= requested:
        raise ValueError("validator returned an observation not linked by the user")
    labels: tuple[MappingPositiveLabel, ...] = ()
    if addition.canonical_concept_key is not None:
        labels = tuple(
            MappingPositiveLabel(
                observation_id=identifier,
                concept_key=addition.canonical_concept_key,
                evidence_family=addition.evidence_family,
                exact_phrase=addition.exact_phrase,
            )
            for identifier in sorted(validated)
        )
    return AdditionLearningEffects(
        user_affinity_positive=True,
        surfacing_positive=True,
        mapping_positive_labels=labels,
        semantic_global_negative=False,
    )


@dataclass(frozen=True, slots=True)
class SurfaceSuppression:
    client_event_id: str
    displayed_assertion_key: str
    evidence_family: str
    surface: str

    def __post_init__(self) -> None:
        for name, value in (
            ("client_event_id", self.client_event_id),
            ("displayed_assertion_key", self.displayed_assertion_key),
            ("evidence_family", self.evidence_family),
            ("surface", self.surface),
        ):
            _bounded_text(name, value, 1024)
        if self.surface not in ALLOWED_ADDITION_SURFACES:
            raise ValueError("suppression surface is not recognized")


@dataclass(frozen=True, slots=True)
class RemovalEffects:
    suppression: SurfaceSuppression
    semantic_global_negative: bool = False
    creates_dislike: bool = False
    creates_false_label: bool = False
    mapping_negative_labels: tuple[object, ...] = ()


def remove_displayed_assertion(
    assertion: ResolutionAssertion,
    *,
    surface: str,
    client_event_id: str,
) -> RemovalEffects:
    """Create a reason-free, surface-local evidence-family suppression."""
    if not isinstance(assertion, ResolutionAssertion):
        raise ValueError("assertion must be a ResolutionAssertion")
    suppression = SurfaceSuppression(
        client_event_id=client_event_id,
        displayed_assertion_key=assertion.key,
        evidence_family=assertion.evidence_family,
        surface=surface,
    )
    return RemovalEffects(suppression=suppression)


def visible_resolution_assertions(
    assertions: Iterable[ResolutionAssertion],
    suppressions: Iterable[SurfaceSuppression],
    *,
    surface: str,
) -> tuple[ResolutionAssertion, ...]:
    """Apply only surface/family suppressions; independent evidence survives."""
    if surface not in ALLOWED_ADDITION_SURFACES:
        raise ValueError("surface is not recognized")
    blocked_families = {
        suppression.evidence_family
        for suppression in suppressions
        if isinstance(suppression, SurfaceSuppression)
        and suppression.surface == surface
    }
    return tuple(
        assertion
        for assertion in assertions
        if isinstance(assertion, ResolutionAssertion)
        and assertion.permission(surface, PermissionUse.NAME)
        and assertion.evidence_family not in blocked_families
    )


__all__ = [
    "ALLOWED_ADDITION_SURFACES",
    "AdditionLearningEffects",
    "AdditionMode",
    "AdditionRelation",
    "AssertionOrigin",
    "ConceptHierarchy",
    "EXPLICIT_ONLY_RELATIONS",
    "MappingPositiveLabel",
    "RemovalEffects",
    "ResolutionAssertion",
    "SuggestionCandidate",
    "SuggestionKind",
    "SurfaceSuppression",
    "UserAddedTerm",
    "accept_suggestion",
    "attach_suggestions",
    "build_resolution_assertions",
    "create_canonical_addition",
    "create_free_text_addition",
    "learning_effects",
    "project_resolution_to_surface",
    "relation_allowed_for_origin",
    "remove_displayed_assertion",
    "visible_resolution_assertions",
]
