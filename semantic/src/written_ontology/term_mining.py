from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from difflib import SequenceMatcher

from .embeddings import EmbeddingBackend, HashingNgramEmbedder
from .models import Observation
from .normalize import accent_fold, cosine, normalize_text
from .safety import InferenceSafetyPolicy


@dataclass(frozen=True, slots=True)
class EmergentTerm:
    normalized_term: str
    type_hint: str | None
    distinct_users: int
    independent_channels: int
    occurrences: int
    privacy_threshold_met: bool


@dataclass(frozen=True, slots=True)
class TermRelationProposal:
    left: str
    right: str
    proposal_kind: str
    lexical_similarity: float
    vector_similarity: float
    distinct_user_support: int
    status: str = "review_only"


class EmergentTermMiner:
    """Privacy-thresholded vocabulary discovery for a curator queue."""

    def __init__(
        self,
        minimum_distinct_users: int = 5,
        safety: InferenceSafetyPolicy | None = None,
        embedder: EmbeddingBackend | None = None,
    ) -> None:
        if type(minimum_distinct_users) is not int or minimum_distinct_users < 5:
            raise ValueError("minimum_distinct_users cannot be lower than the privacy floor of 5")
        self.minimum_distinct_users = minimum_distinct_users
        self.safety = safety or InferenceSafetyPolicy()
        self.embedder = embedder or HashingNgramEmbedder()
        self._term_users: dict[tuple[str, str | None], set[str]] = defaultdict(set)
        self._term_channels: dict[tuple[str, str | None], set[str]] = defaultdict(set)
        self._term_occurrences: Counter[tuple[str, str | None]] = Counter()
        self._user_terms: dict[str, set[tuple[str, str | None]]] = defaultdict(set)

    def add_observation(self, user_id: str, observation: Observation) -> None:
        if not isinstance(observation, Observation) or not isinstance(observation.terms, tuple):
            return
        if not isinstance(user_id, str) or not user_id.strip() or len(user_id) > 512:
            return
        if (
            not isinstance(observation.independence_group, str)
            or not observation.independence_group.strip()
        ):
            return
        for term in observation.terms:
            if not self.safety.term_is_safe_for_global_mining(observation, term):
                continue
            if (
                not isinstance(term.text, str)
                or not isinstance(term.normalized, str)
                or not term.text.strip()
                or len(term.text) > 512
                or term.normalized != normalize_text(term.text)
            ):
                continue
            key = (term.normalized, term.type_hint)
            self._term_users[key].add(user_id)
            self._term_channels[key].add(observation.independence_group)
            self._term_occurrences[key] += 1
            self._user_terms[user_id].add(key)

    def _summaries(self, *, include_below_threshold: bool) -> tuple[EmergentTerm, ...]:
        result = []
        for key in sorted(self._term_occurrences):
            normalized, type_hint = key
            users = len(self._term_users[key])
            if not include_below_threshold and users < self.minimum_distinct_users:
                continue
            result.append(
                EmergentTerm(
                    normalized_term=normalized,
                    type_hint=type_hint,
                    distinct_users=users,
                    independent_channels=len(self._term_channels[key]),
                    occurrences=self._term_occurrences[key],
                    privacy_threshold_met=users >= self.minimum_distinct_users,
                )
            )
        return tuple(result)

    def terms(self) -> tuple[EmergentTerm, ...]:
        """Return only privacy-thresholded terms eligible for curator review."""
        return self._summaries(include_below_threshold=False)

    def private_count_summary(self) -> dict[str, int]:
        """Return non-identifying local counters without rare term text."""
        below_threshold = sum(
            len(users) < self.minimum_distinct_users
            for users in self._term_users.values()
        )
        return {
            "distinct_term_keys": len(self._term_occurrences),
            "below_threshold_term_keys": below_threshold,
            "occurrences": sum(self._term_occurrences.values()),
        }

    def relation_proposals(self) -> tuple[TermRelationProposal, ...]:
        eligible = [
            key
            for key in sorted(self._term_occurrences)
            if len(self._term_users[key]) >= self.minimum_distinct_users
        ]
        if len(eligible) < 2:
            return ()
        encoded = self.embedder.encode([key[0] for key in eligible])
        vectors = dict(zip(eligible, encoded, strict=True))
        proposals: list[TermRelationProposal] = []
        for index, left in enumerate(eligible):
            for right in eligible[index + 1 :]:
                if left[1] and right[1] and left[1] != right[1]:
                    continue
                shared_users = len(self._term_users[left] & self._term_users[right])
                if shared_users < self.minimum_distinct_users:
                    continue
                lexical = SequenceMatcher(None, accent_fold(left[0]), accent_fold(right[0])).ratio()
                vector_similarity = max(0.0, cosine(vectors[left], vectors[right]))
                if max(lexical, vector_similarity) < 0.65:
                    continue
                # Even very similar recurring terms remain proposals. Alias
                # promotion additionally requires external or curator evidence.
                kind = "alias" if lexical >= 0.90 and vector_similarity >= 0.85 else "related"
                proposals.append(
                    TermRelationProposal(
                        left=left[0],
                        right=right[0],
                        proposal_kind=kind,
                        lexical_similarity=round(lexical, 8),
                        vector_similarity=round(vector_similarity, 8),
                        distinct_user_support=shared_users,
                    )
                )
        return tuple(proposals)
