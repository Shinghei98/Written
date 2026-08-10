from __future__ import annotations

import csv
from collections import defaultdict, deque
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

from .models import Concept, ConceptEdge, InferencePolicyName, MappingState, Term
from .normalize import accent_fold, normalize_text
from .safety import ALLOWED_INFERRED_KINDS, InferenceSafetyPolicy, PROHIBITED_INFERRED_KINDS


_AUTO_ACCEPT_ALIAS_TYPES = {"preferred", "alternate"}


@dataclass(frozen=True, slots=True)
class AliasResolution:
    concept_key: str
    confidence: float
    method: str
    state: MappingState
    margin: float | None


class OntologyGraph:
    def __init__(
        self,
        concepts: dict[str, Concept],
        edges: tuple[ConceptEdge, ...],
        aliases: dict[str, list[tuple[str, float, str]]],
    ) -> None:
        self.concepts = concepts
        self.edges = edges
        self.aliases = aliases
        self._outgoing: dict[str, list[ConceptEdge]] = defaultdict(list)
        self._incoming: dict[str, list[ConceptEdge]] = defaultdict(list)
        for edge in edges:
            self._outgoing[edge.subject_key].append(edge)
            self._incoming[edge.object_key].append(edge)

    @classmethod
    def from_seed_dir(cls, seed_dir: str | Path) -> "OntologyGraph":
        seed_dir = Path(seed_dir)
        concepts: dict[str, Concept] = {}
        with (seed_dir / "seed_concepts.csv").open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                key = row["concept_key"].strip()
                if not key or key in concepts:
                    raise ValueError(f"duplicate or empty concept key: {key!r}")
                policy_value = row["inference_policy"]
                if policy_value == "blocked":
                    policy_value = "prohibited"
                if not row["preferred_label"].strip():
                    raise ValueError(f"concept {key!r} has an empty preferred label")
                kind = row["concept_kind"].strip().casefold().replace("-", "_").replace(" ", "_")
                if kind not in ALLOWED_INFERRED_KINDS | PROHIBITED_INFERRED_KINDS:
                    raise ValueError(f"concept {key!r} has an unknown kind: {kind!r}")
                sensitivity = row["sensitivity"].strip().casefold()
                if sensitivity not in {"ordinary", "private", "sensitive"}:
                    raise ValueError(
                        f"concept {key!r} has an unknown sensitivity: {sensitivity!r}"
                    )
                status = row["status"].strip().casefold()
                if status not in {"active", "draft", "blocked"}:
                    raise ValueError(f"concept {key!r} has an unknown status: {status!r}")
                concepts[key] = Concept(
                    key=key,
                    label=row["preferred_label"],
                    kind=kind,
                    sensitivity=sensitivity,
                    inference_policy=InferencePolicyName(policy_value),
                    status=status,
                    definition=row.get("notes") or None,
                )

        aliases: dict[str, list[tuple[str, float, str]]] = defaultdict(list)
        for concept in concepts.values():
            aliases[normalize_text(concept.label)].append((concept.key, 1.0, "preferred"))
            folded = accent_fold(concept.label)
            if folded != normalize_text(concept.label):
                aliases[folded].append((concept.key, 0.99, "preferred_folded"))

        with (seed_dir / "seed_aliases.csv").open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                key = row["concept_key"]
                if key not in concepts:
                    raise ValueError(f"alias references unknown concept: {key!r}")
                confidence = float(row["confidence"])
                if not 0.0 <= confidence <= 1.0:
                    raise ValueError(f"alias confidence is outside [0, 1]: {confidence}")
                normalized = normalize_text(row["alias"])
                if not normalized:
                    raise ValueError(f"concept {key!r} has an empty normalized alias")
                aliases[normalized].append((key, confidence, row["alias_type"]))
                folded = accent_fold(row["alias"])
                if folded != normalized:
                    aliases[folded].append((key, confidence * 0.99, "accent_folded"))

        edges: list[ConceptEdge] = []
        seen_edges: set[tuple[str, str, str]] = set()
        with (seed_dir / "seed_relations.csv").open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                subject_key = row["subject_key"]
                object_key = row["object_key"]
                if subject_key not in concepts or object_key not in concepts:
                    raise ValueError(
                        f"edge has a dangling endpoint: {subject_key!r} -> {object_key!r}"
                    )
                confidence = float(row["confidence"])
                if not 0.0 <= confidence <= 1.0:
                    raise ValueError(f"edge confidence is outside [0, 1]: {confidence}")
                predicate = row["predicate_key"]
                if predicate not in {
                    "broader",
                    "about",
                    "associated_with_place",
                    "supports_cultural_affinity_candidate",
                }:
                    raise ValueError(f"seed edge uses an unapproved predicate: {predicate!r}")
                if (
                    predicate == "supports_cultural_affinity_candidate"
                    and concepts[object_key].kind != "place"
                ):
                    raise ValueError("cultural-affinity evidence must target a place")
                edge_key = (subject_key, predicate, object_key)
                if edge_key in seen_edges:
                    raise ValueError(f"duplicate seed edge: {edge_key!r}")
                seen_edges.add(edge_key)
                edges.append(
                    ConceptEdge(
                        subject_key=subject_key,
                        predicate_key=predicate,
                        object_key=object_key,
                        confidence=confidence,
                        provenance_type=row["provenance_type"],
                        status=row["status"],
                    )
                )
        return cls(concepts, tuple(edges), dict(aliases))

    def outgoing(self, concept_key: str, predicate: str | None = None) -> tuple[ConceptEdge, ...]:
        edges = self._outgoing.get(concept_key, ())
        if predicate is None:
            return tuple(edges)
        return tuple(edge for edge in edges if edge.predicate_key == predicate)

    def incoming(self, concept_key: str, predicate: str | None = None) -> tuple[ConceptEdge, ...]:
        edges = self._incoming.get(concept_key, ())
        if predicate is None:
            return tuple(edges)
        return tuple(edge for edge in edges if edge.predicate_key == predicate)

    def resolve_alias(
        self,
        term: Term,
        *,
        fuzzy_threshold: float = 0.87,
        minimum_margin: float = 0.08,
    ) -> tuple[AliasResolution, ...]:
        exact = self.aliases.get(term.normalized) or self.aliases.get(accent_fold(term.text))
        if exact:
            by_concept: dict[str, list[tuple[float, str]]] = defaultdict(list)
            for key, confidence, alias_type in exact:
                if key in self.concepts:
                    by_concept[key].append((confidence, alias_type))

            # A label collision is ambiguous even if a type hint makes one
            # candidate look more plausible. Type hints may reject impossible
            # candidates, but they must not silently resolve a collision.
            collision = len(by_concept) > 1
            resolutions: list[AliasResolution] = []
            for key, matches in by_concept.items():
                concept = self.concepts[key]
                auto_accept_confidences = [
                    confidence
                    for confidence, alias_type in matches
                    if alias_type in _AUTO_ACCEPT_ALIAS_TYPES
                ]
                confidence = max(
                    auto_accept_confidences
                    or [value for value, _alias_type in matches]
                )
                if not self._type_compatible(term, concept):
                    state = MappingState.REJECTED
                elif (
                    not collision
                    and concept.status == "active"
                    and auto_accept_confidences
                ):
                    state = MappingState.ACCEPTED
                else:
                    # Related/source/folded aliases, inactive concepts, and
                    # collisions remain review candidates.
                    state = MappingState.CANDIDATE
                resolutions.append(
                    AliasResolution(key, confidence, "curated_alias", state, None)
                )
            return tuple(
                sorted(
                    resolutions,
                    key=lambda item: (-item.confidence, item.concept_key),
                )
            )

        scores: list[tuple[float, str]] = []
        query = accent_fold(term.text)
        for alias, candidates in self.aliases.items():
            similarity = SequenceMatcher(None, query, accent_fold(alias)).ratio()
            for concept_key, alias_confidence, _alias_type in candidates:
                scores.append((similarity * alias_confidence, concept_key))
        scores.sort(key=lambda item: (-item[0], item[1]))
        if not scores:
            return ()
        best_score, best_key = scores[0]
        second_score = next((score for score, key in scores[1:] if key != best_key), 0.0)
        margin = best_score - second_score
        concept = self.concepts[best_key]
        if not self._type_compatible(term, concept):
            state = MappingState.REJECTED
        else:
            # Fuzzy matching is candidate generation, not semantic
            # entailment. Threshold and margin can prioritize review but do
            # not turn similarity into accepted evidence.
            state = MappingState.CANDIDATE
        return (
            AliasResolution(
                concept_key=best_key,
                confidence=best_score,
                method="lexical",
                state=state,
                margin=margin,
            ),
        )

    @staticmethod
    def _type_compatible(term: Term, concept: Concept) -> bool:
        if not term.type_hint:
            return True
        compatible_kinds = {
            "creator": {"creator", "organization"},
            "channel": {"channel"},
            "organization": {"organization"},
            "work": {"work"},
            "genre": {"genre", "topic"},
            "topic": {"topic", "genre", "culture", "cuisine"},
            "activity": {"activity", "sport"},
            "event": {"event"},
            "place": {"place"},
            "language": {"language"},
        }
        normalized_hint = term.type_hint.casefold().strip().replace("-", "_").replace(" ", "_")
        allowed = compatible_kinds.get(normalized_hint)
        return allowed is not None and concept.kind in allowed

    def safe_targets(
        self,
        start_key: str,
        predicate: str,
        *,
        max_hops: int = 1,
        safety: InferenceSafetyPolicy | None = None,
    ) -> tuple[tuple[str, tuple[ConceptEdge, ...]], ...]:
        """Traverse one whitelisted predicate; arbitrary related-to walks are forbidden."""
        safety = safety or InferenceSafetyPolicy()
        start = self.concepts.get(start_key)
        if (
            start is None
            or start.status != "active"
            or not safety.concept_is_inferable(start).allowed
        ):
            return ()
        hop_limit = max(0, max_hops)
        if predicate != "broader":
            hop_limit = min(hop_limit, 1)
        queue: deque[tuple[str, tuple[ConceptEdge, ...]]] = deque([(start_key, ())])
        results: list[tuple[str, tuple[ConceptEdge, ...]]] = []
        visited = {start_key}
        while queue:
            key, path = queue.popleft()
            if len(path) >= hop_limit:
                continue
            for edge in self.outgoing(key, predicate):
                if not safety.edge_is_inferable(edge).allowed:
                    continue
                target = self.concepts.get(edge.object_key)
                if (
                    target is None
                    or target.status != "active"
                    or not safety.concept_is_inferable(target).allowed
                ):
                    continue
                if edge.object_key in visited:
                    continue
                next_path = path + (edge,)
                visited.add(edge.object_key)
                results.append((edge.object_key, next_path))
                queue.append((edge.object_key, next_path))
        return tuple(results)

    def affinity_for_target(self, target_key: str) -> Concept | None:
        candidates: dict[str, Concept] = {}
        for edge in self.incoming(target_key, "about"):
            concept = self.concepts.get(edge.subject_key)
            if (
                concept
                and concept.kind == "affinity"
                and concept.status == "active"
                and edge.status == "active"
            ):
                candidates[concept.key] = concept
        if len(candidates) != 1:
            return None
        return next(iter(candidates.values()))
