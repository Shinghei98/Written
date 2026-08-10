from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass
from itertools import combinations

from .graph import OntologyGraph
from .mapping import SOURCE_LAYOUT
from .models import (
    AssertionCandidate,
    ConceptScore,
    Evidence,
    SourceBreakdown,
)
from .safety import InferenceSafetyPolicy


@dataclass(frozen=True, slots=True)
class ScoringConfig:
    per_lineage_cap: float = 0.75
    source_alpha: float = 0.72
    cross_source_gamma: float = 0.16
    breadth_threshold: float = 0.12
    minimum_convergence_groups: int = 2
    convergence_path_attenuation: float = 0.82
    minimum_convergence_strength: float = 0.38
    minimum_evidence_quality: float = 0.45
    minimum_stability: float = 0.08


class FusionEngine:
    def __init__(self, config: ScoringConfig | None = None) -> None:
        self.config = config or ScoringConfig()
        bounded = {
            "per_lineage_cap": self.config.per_lineage_cap,
            "source_alpha": self.config.source_alpha,
            "cross_source_gamma": self.config.cross_source_gamma,
            "breadth_threshold": self.config.breadth_threshold,
            "convergence_path_attenuation": self.config.convergence_path_attenuation,
            "minimum_convergence_strength": self.config.minimum_convergence_strength,
            "minimum_evidence_quality": self.config.minimum_evidence_quality,
            "minimum_stability": self.config.minimum_stability,
        }
        if any(
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or not 0.0 <= value <= 1.0
            for value in bounded.values()
        ):
            raise ValueError("all scoring weights and thresholds must be finite in [0, 1]")
        if (
            type(self.config.minimum_convergence_groups) is not int
            or self.config.minimum_convergence_groups < 2
        ):
            raise ValueError("cross-source convergence requires at least two groups")

    @staticmethod
    def _valid_evidence(item: Evidence) -> bool:
        if not isinstance(item, Evidence):
            return False
        values = (
            item.mapping_confidence,
            item.action_weight,
            item.source_quality,
            item.field_quality,
            item.recency_weight,
            item.recency_quality,
            item.path_weight,
        )
        return (
            all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in values)
            and all(math.isfinite(value) and 0.0 <= value <= 1.0 for value in values)
            and all(
                isinstance(value, str) and bool(value.strip()) and len(value) <= 1024
                for value in (
                    item.observation_id,
                    item.concept_key,
                    item.source,
                    item.evidence_channel,
                    item.independence_group,
                    item.content_lineage,
                )
            )
            and SOURCE_LAYOUT.get(item.source)
            == (item.evidence_channel, item.independence_group)
            and isinstance(item.cross_source_fusion_allowed, bool)
            and all(
                isinstance(value, str)
                and bool(value.strip())
                and len(value) <= 128
                for value in (
                    item.recency_policy_version,
                    item.recency_rule_id,
                    item.recency_status,
                )
            )
        )

    def score(
        self,
        concept_key: str,
        evidence: tuple[Evidence, ...] | list[Evidence],
        *,
        usable_source_count: int = 0,
        missing_source_count: int = 0,
    ) -> ConceptScore:
        relevant = [
            item
            for item in evidence
            if self._valid_evidence(item) and item.concept_key == concept_key
        ]

        # A gated provider may still support a source-local private score, but
        # it cannot be merged with another independence group. Compare the
        # authorized multi-group partition with each gated local partition and
        # return the strongest one. This preserves monotonicity (merely having
        # another source cannot erase a stronger local view) without creating
        # unauthorized breadth or synergy.
        relevant_groups = {item.independence_group for item in relevant}
        if len(relevant_groups) > 1 and any(
            not item.cross_source_fusion_allowed for item in relevant
        ):
            authorized = [
                item for item in relevant if item.cross_source_fusion_allowed
            ]
            gated_groups = sorted(
                {
                    item.independence_group
                    for item in relevant
                    if not item.cross_source_fusion_allowed
                }
            )
            partitions = ([authorized] if authorized else []) + [
                [item for item in relevant if item.independence_group == group]
                for group in gated_groups
            ]
            scores = [
                self.score(
                    concept_key,
                    partition,
                    usable_source_count=usable_source_count,
                    missing_source_count=missing_source_count,
                )
                for partition in partitions
                if partition
            ]
            return max(
                scores,
                key=lambda item: (
                    item.strength,
                    item.evidence_quality,
                    item.mapping_agreement,
                    item.breadth,
                ),
                default=ConceptScore(
                    concept_key=concept_key,
                    strength=0.0,
                    mapping_agreement=0.0,
                    evidence_quality=0.0,
                    breadth=0,
                    stability=0.0,
                    source_breakdown=(),
                    usable_source_count=usable_source_count,
                    missing_source_count=missing_source_count,
                ),
            )

        # A cross-posted recording or episode can appear through more than one
        # connector. If a canonical lineage occurs in several independence
        # groups, retain only its strongest contribution before calculating
        # breadth. One piece of content cannot manufacture cross-source
        # convergence.
        lineage_groups: dict[str, set[str]] = defaultdict(set)
        for item in relevant:
            lineage_groups[item.content_lineage].add(item.independence_group)
        shared_lineages = {
            lineage for lineage, groups in lineage_groups.items() if len(groups) > 1
        }
        if shared_lineages:
            retained = [item for item in relevant if item.content_lineage not in shared_lineages]
            for lineage in sorted(shared_lineages):
                candidates = [item for item in relevant if item.content_lineage == lineage]
                retained.append(
                    max(
                        candidates,
                        key=lambda item: (
                            item.raw_contribution,
                            item.independence_group,
                            item.observation_id,
                        ),
                    )
                )
            relevant = retained

        by_group: dict[str, list[Evidence]] = defaultdict(list)
        for item in relevant:
            by_group[item.independence_group].append(item)

        breakdown: list[SourceBreakdown] = []
        group_strengths: dict[str, float] = {}
        for group, items in sorted(by_group.items()):
            by_lineage: dict[str, list[Evidence]] = defaultdict(list)
            for item in items:
                by_lineage[item.content_lineage].append(item)
            lineage_sum = 0.0
            for lineage_items in by_lineage.values():
                unique_observations: dict[str, Evidence] = {}
                for item in lineage_items:
                    current = unique_observations.get(item.observation_id)
                    if current is None or item.raw_contribution > current.raw_contribution:
                        unique_observations[item.observation_id] = item
                lineage_sum += min(
                    self.config.per_lineage_cap,
                    sum(item.raw_contribution for item in unique_observations.values()),
                )
            strength = 1.0 - math.exp(-lineage_sum)
            weight_total = sum(item.raw_contribution for item in items)
            mapping_agreement = (
                sum(item.mapping_confidence * item.raw_contribution for item in items) / weight_total
                if weight_total
                else 0.0
            )
            evidence_quality = (
                sum(
                    (
                        item.mapping_confidence
                        * item.source_quality
                        * item.field_quality
                        * item.recency_quality
                        * item.path_weight
                    )
                    * item.raw_contribution
                    for item in items
                )
                / weight_total
                if weight_total
                else 0.0
            )
            group_strengths[group] = strength
            breakdown.append(
                SourceBreakdown(
                    independence_group=group,
                    strength=strength,
                    mapping_agreement=mapping_agreement,
                    evidence_quality=evidence_quality,
                    unique_lineages=len(by_lineage),
                    evidence_count=len({item.observation_id for item in items}),
                )
            )

        base = 1.0
        for strength in group_strengths.values():
            base *= 1.0 - self.config.source_alpha * strength
        base = 1.0 - base
        synergy = self.config.cross_source_gamma * sum(
            left * right for left, right in combinations(group_strengths.values(), 2)
        )
        strength = min(1.0, base + synergy)
        breadth = sum(value >= self.config.breadth_threshold for value in group_strengths.values())
        quality_weight = sum(item.strength for item in breakdown)
        mapping_agreement = (
            sum(item.strength * item.mapping_agreement for item in breakdown) / quality_weight
            if quality_weight
            else 0.0
        )
        evidence_quality = (
            sum(item.strength * item.evidence_quality for item in breakdown) / quality_weight
            if quality_weight
            else 0.0
        )

        if len(group_strengths) <= 1 or strength == 0:
            stability = 0.0
        else:
            leave_one_out: list[float] = []
            for removed_group in group_strengths:
                remaining = {
                    key: value for key, value in group_strengths.items() if key != removed_group
                }
                remaining_base = 1.0
                for value in remaining.values():
                    remaining_base *= 1.0 - self.config.source_alpha * value
                remaining_base = 1.0 - remaining_base
                remaining_synergy = self.config.cross_source_gamma * sum(
                    left * right for left, right in combinations(remaining.values(), 2)
                )
                leave_one_out.append(min(1.0, remaining_base + remaining_synergy))
            stability = min(leave_one_out) / strength

        return ConceptScore(
            concept_key=concept_key,
            strength=round(strength, 8),
            mapping_agreement=round(mapping_agreement, 8),
            evidence_quality=round(evidence_quality, 8),
            breadth=breadth,
            stability=round(min(1.0, stability), 8),
            source_breakdown=tuple(breakdown),
            usable_source_count=usable_source_count,
            missing_source_count=missing_source_count,
        )


class ConvergenceEngine:
    """Projects only through an explicitly allowed shared-target relation."""

    def __init__(
        self,
        graph: OntologyGraph,
        fusion: FusionEngine | None = None,
        safety: InferenceSafetyPolicy | None = None,
    ) -> None:
        self.graph = graph
        self.fusion = fusion or FusionEngine()
        self.safety = safety or InferenceSafetyPolicy()

    def infer_shared_target_affinities(
        self,
        evidence: tuple[Evidence, ...] | list[Evidence],
    ) -> tuple[AssertionCandidate, ...]:
        relation = "supports_cultural_affinity_candidate"
        projected: dict[str, list[Evidence]] = defaultdict(list)
        for item in evidence:
            if not self.fusion._valid_evidence(item):
                continue
            if not item.cross_source_fusion_allowed:
                # Shared-target convergence is inherently cross-source.
                continue
            for target_key, path in self.graph.safe_targets(
                item.concept_key,
                relation,
                max_hops=1,
                safety=self.safety,
            ):
                affinity = self.graph.affinity_for_target(target_key)
                if affinity is None or not self.safety.concept_is_inferable(affinity).allowed:
                    continue
                path_weight = item.path_weight
                path_steps = list(item.evidence_path)
                for edge in path:
                    path_weight *= edge.confidence * self.fusion.config.convergence_path_attenuation
                    path_steps.append(
                        {
                            "step": "typed_graph_edge",
                            "subject": edge.subject_key,
                            "predicate": edge.predicate_key,
                            "object": edge.object_key,
                            "confidence": edge.confidence,
                        }
                    )
                projected[affinity.key].append(
                    Evidence(
                        observation_id=item.observation_id,
                        concept_key=affinity.key,
                        source=item.source,
                        evidence_channel=item.evidence_channel,
                        independence_group=item.independence_group,
                        content_lineage=item.content_lineage,
                        mapping_confidence=item.mapping_confidence,
                        action_weight=item.action_weight,
                        source_quality=item.source_quality,
                        field_quality=item.field_quality,
                        recency_weight=item.recency_weight,
                        recency_quality=item.recency_quality,
                        recency_policy_version=item.recency_policy_version,
                        recency_rule_id=item.recency_rule_id,
                        recency_status=item.recency_status,
                        path_weight=path_weight,
                        cross_source_fusion_allowed=(
                            item.cross_source_fusion_allowed
                        ),
                        evidence_path=tuple(path_steps),
                    )
                )

        assertions: list[AssertionCandidate] = []
        for affinity_key, items in sorted(projected.items()):
            score = self.fusion.score(affinity_key, items)
            if score.breadth < self.fusion.config.minimum_convergence_groups:
                continue
            if score.strength < self.fusion.config.minimum_convergence_strength:
                continue
            if score.evidence_quality < self.fusion.config.minimum_evidence_quality:
                continue
            if score.stability < self.fusion.config.minimum_stability:
                continue
            affinity = self.graph.concepts[affinity_key]
            assertions.append(
                AssertionCandidate(
                    key=f"affinity_to::{affinity_key}",
                    predicate="affinity_to",
                    concept_key=affinity_key,
                    label=affinity.label,
                    state="pending_user_review",
                    score=score,
                    explanation_paths=tuple(item.evidence_path for item in items),
                )
            )
        return tuple(assertions)
