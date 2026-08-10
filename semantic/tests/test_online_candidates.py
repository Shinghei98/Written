from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import datetime, timezone

from written_ontology.graph import OntologyGraph
from written_ontology.mapping import ObservationMapper
from written_ontology.models import (
    Concept,
    ExternalCandidate,
    InferencePolicyName,
    MappingState,
    Observation,
    Term,
)


NOW = datetime(2026, 8, 10, tzinfo=timezone.utc)


class RecordingProvider:
    provider_name = "fixture"

    def __init__(
        self,
        results: tuple[ExternalCandidate, ...] = (),
        *,
        error: Exception | None = None,
    ) -> None:
        self.results = results
        self.error = error
        self.calls = 0

    def resolve(
        self,
        observation: Observation,
        term: Term,
    ) -> tuple[ExternalCandidate, ...]:
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.results


def external_candidate(
    *,
    entity_kind: str | None = "creator",
    label: str = "Verified Artist",
    external_id: str = "Q123",
    retrieval_score: float = 0.83,
) -> ExternalCandidate:
    return ExternalCandidate(
        provider="fixture",
        external_id=external_id,
        label=label,
        description="Public catalog fixture",
        entity_kind=entity_kind,
        aliases=(label,),
        proposed_edges=(
            {
                "predicate": "genre",
                "target_external_id": "Q456",
                "status": "candidate_only",
            },
        ),
        retrieval_score=retrieval_score,
        provenance={
            "provider": "fixture",
            "external_id": external_id,
            "retrieved_at": "2026-08-10T00:00:00+00:00",
            "payload_sha256": "fixture-hash",
            "license": "fixture-license",
            "status": "candidate_only",
        },
    )


def observation(
    *,
    privacy_class: str = "public_catalog",
    allow_external_resolution: bool = True,
    source: str = "apple_music",
    type_hint: str = "creator",
) -> Observation:
    item_term = Term(
        text="Verified Artist",
        normalized="verified artist",
        role="creator",
        source_field="creator",
        type_hint=type_hint,
        safe_for_online=True,
    )
    return Observation(
        id="obs-online-1",
        source=source,
        data_type="artist",
        action="followed_artist",
        evidence_channel="music",
        independence_group="music",
        occurred_at=NOW,
        collected_at=NOW,
        terms=(item_term,),
        record_fingerprint="fingerprint-online-1",
        content_lineage="lineage-online-1",
        privacy_class=privacy_class,
        allow_external_resolution=allow_external_resolution,
        metadata={
            "has_verified_catalog_id": True,
            "catalog_namespace": "fixture_catalog",
        },
    )


class OnlineCandidateTests(unittest.TestCase):
    def test_private_calendar_never_calls_provider(self) -> None:
        provider = RecordingProvider((external_candidate(),))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )
        private_event = observation(
            privacy_class="private_text",
            source="apple_calendar",
        )

        self.assertEqual(mapper.map_observation(private_event), ())
        self.assertEqual(provider.calls, 0)

    def test_public_verified_term_yields_external_candidate_only(self) -> None:
        external = external_candidate(retrieval_score=0.83)
        provider = RecordingProvider((external,))
        graph = OntologyGraph(concepts={}, edges=(), aliases={})
        mapper = ObservationMapper(graph, providers=(provider,))
        item = observation()

        candidates = mapper.map_observation(item)

        self.assertEqual(provider.calls, 1)
        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual(candidate.state, MappingState.CANDIDATE)
        self.assertEqual(candidate.method, "external_candidate")
        self.assertEqual(candidate.concept_key, "external:fixture:Q123")
        self.assertEqual(candidate.confidence, 0.83)
        self.assertNotIn(candidate.concept_key, graph.concepts)
        self.assertEqual(mapper.accepted_evidence(item, candidates), ())
        external_step = candidate.evidence_path[-1]
        self.assertEqual(external_step["retrieval_score"], 0.83)
        self.assertEqual(external_step["provenance"], external.provenance)

    def test_provider_failure_fails_closed(self) -> None:
        provider = RecordingProvider(error=RuntimeError("provider unavailable"))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )

        self.assertEqual(mapper.map_observation(observation()), ())
        self.assertEqual(provider.calls, 1)

    def test_public_flag_without_verified_catalog_provenance_never_calls_provider(self) -> None:
        provider = RecordingProvider((external_candidate(),))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )
        unverified = replace(observation(), metadata={})
        self.assertEqual(mapper.map_observation(unverified), ())
        self.assertEqual(provider.calls, 0)

    def test_string_false_flags_cannot_enable_provider_egress(self) -> None:
        provider = RecordingProvider((external_candidate(),))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )
        base = observation()
        malformed_term = replace(base.terms[0], safe_for_online="false")  # type: ignore[arg-type]
        malformed = replace(
            base,
            allow_external_resolution="false",  # type: ignore[arg-type]
            terms=(malformed_term,),
        )
        self.assertEqual(mapper.map_observation(malformed), ())
        self.assertEqual(provider.calls, 0)

    def test_unsafe_entity_kind_is_rejected(self) -> None:
        provider = RecordingProvider((external_candidate(entity_kind="identity"),))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )

        self.assertEqual(mapper.map_observation(observation()), ())
        self.assertEqual(provider.calls, 1)

    def test_type_incompatible_external_result_is_dropped(self) -> None:
        provider = RecordingProvider((external_candidate(entity_kind="place"),))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )

        self.assertEqual(mapper.map_observation(observation(type_hint="creator")), ())

    def test_string_retrieval_score_fails_closed(self) -> None:
        malformed = replace(external_candidate(), retrieval_score="0.7")  # type: ignore[arg-type]
        provider = RecordingProvider((malformed,))
        mapper = ObservationMapper(
            OntologyGraph(concepts={}, edges=(), aliases={}),
            providers=(provider,),
        )
        self.assertEqual(mapper.map_observation(observation()), ())

    def test_label_match_cannot_promote_external_result(self) -> None:
        local = Concept(
            key="creator:verified_artist",
            label="Verified Artist",
            kind="creator",
            sensitivity="ordinary",
            inference_policy=InferencePolicyName.INFERABLE,
        )
        provider = RecordingProvider((external_candidate(label=local.label),))
        graph = OntologyGraph(
            concepts={local.key: local},
            edges=(),
            aliases={"verified artist": [(local.key, 1.0, "preferred")]},
        )
        mapper = ObservationMapper(graph, providers=(provider,))

        candidates = mapper.map_observation(observation())
        local_candidate = next(item for item in candidates if item.method == "curated_alias")
        online_candidate = next(item for item in candidates if item.method == "external_candidate")
        self.assertEqual(local_candidate.state, MappingState.ACCEPTED)
        self.assertEqual(online_candidate.state, MappingState.CANDIDATE)


if __name__ == "__main__":
    unittest.main()
