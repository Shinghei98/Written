from __future__ import annotations

from ..models import ExternalCandidate, Observation, Term
from ..safety import InferenceSafetyPolicy


class StaticKnowledgeProvider:
    provider_name = "fixture"

    def __init__(
        self,
        candidates: dict[str, tuple[ExternalCandidate, ...]] | None = None,
        *,
        safety: InferenceSafetyPolicy | None = None,
    ) -> None:
        self.candidates = candidates or {}
        self.safety = safety or InferenceSafetyPolicy()

    def resolve(self, observation: Observation, term: Term) -> tuple[ExternalCandidate, ...]:
        if not self.safety.term_may_leave_device_boundary(observation, term):
            return ()
        return self.candidates.get(term.normalized, ())
