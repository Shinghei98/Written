from __future__ import annotations

from typing import Protocol

from ..models import ExternalCandidate, Observation, Term


_SAFE_EXTERNAL_ENTITY_KINDS = {
    "activity",
    "creator",
    "cuisine",
    "culture",
    "event",
    "genre",
    "language",
    "medium",
    "organization",
    "place",
    "sport",
    "topic",
    "work",
}

_TYPE_COMPATIBLE_EXTERNAL_KINDS = {
    "activity": {"activity", "sport"},
    "creator": {"creator", "organization"},
    "cuisine": {"cuisine", "topic"},
    "event": {"event"},
    "genre": {"genre", "topic"},
    "language": {"language"},
    "medium": {"medium"},
    "organization": {"organization"},
    "place": {"place"},
    "sport": {"sport", "activity"},
    "topic": {"topic", "genre", "culture", "cuisine"},
    "work": {"work"},
}


def external_candidate_is_type_compatible(
    term: Term,
    candidate: ExternalCandidate,
) -> bool:
    """Fail closed unless both sides carry compatible, ordinary entity types."""
    if not candidate.entity_kind or not term.type_hint:
        return False
    entity_kind = candidate.entity_kind.casefold().strip().replace("-", "_").replace(" ", "_")
    if entity_kind not in _SAFE_EXTERNAL_ENTITY_KINDS:
        return False
    type_hint = term.type_hint.casefold().strip().replace("-", "_").replace(" ", "_")
    allowed = _TYPE_COMPATIBLE_EXTERNAL_KINDS.get(type_hint)
    return allowed is not None and entity_kind in allowed


class KnowledgeProvider(Protocol):
    provider_name: str

    def resolve(self, observation: Observation, term: Term) -> tuple[ExternalCandidate, ...]:
        """Return provenance-bearing candidates; never mutate the ontology."""
        ...
