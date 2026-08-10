from __future__ import annotations

import math
import unittest

from written_ontology.surfaces import (
    CuratedAssociation,
    DirectionalBioSelector,
    DyadicMatcher,
    Explicitness,
    IcebreakerGenerator,
    MemoriesOrganizer,
    PermissionUse,
    SemanticGraph,
    SourceFact,
    SurfaceGrant,
    SurfaceAssertion,
    TransportConfig,
    WordingLicense,
    healthkit_fitness_surface_grants,
    youtube_policy_surface_grants,
)


ALL_SURFACES = frozenset({"memories", "matching", "bio", "icebreaker"})


def fact(
    key: str,
    text: str,
    *,
    group: str = "music",
    permissions: frozenset[str] = ALL_SURFACES,
    raw: bool = False,
    future: bool = False,
    private_calendar: bool = False,
    grants: tuple[SurfaceGrant, ...] = (),
    provider: str = "ordinary",
    policy_locked: bool = False,
    data_use_purpose: str = "general_social",
) -> SourceFact:
    return SourceFact(
        key=key,
        display_text=text,
        source_group=group,
        surface_permissions=permissions,
        is_raw=raw,
        is_future=future,
        is_private_calendar=private_calendar,
        surface_grants=grants,
        provider=provider,
        policy_locked=policy_locked,
        data_use_purpose=data_use_purpose,
    )


def assertion(
    key: str,
    concept: str,
    label: str,
    *,
    predicate: str = "likes",
    hub: str = "hub:interests",
    strength: float = 0.80,
    mapping: float = 0.90,
    quality: float = 0.90,
    explicitness: Explicitness = Explicitness.CONFIRMED,
    specificity: float = 0.70,
    information: float = 0.70,
    mass: float = 0.50,
    groups: frozenset[str] = frozenset({"music"}),
    permissions: frozenset[str] = ALL_SURFACES,
    facts: tuple[SourceFact, ...] = (),
    grants: tuple[SurfaceGrant, ...] = (),
    evidence_family: str | None = None,
) -> SurfaceAssertion:
    return SurfaceAssertion(
        key=key,
        predicate=predicate,
        concept_key=concept,
        hub_key=hub,
        label=label,
        strength=strength,
        mapping_quality=mapping,
        evidence_quality=quality,
        explicitness=explicitness,
        specificity=specificity,
        information_content=information,
        mass=mass,
        source_groups=groups,
        surface_permissions=permissions,
        source_facts=facts,
        surface_grants=grants,
        evidence_family=evidence_family,
    )


def base_graph() -> SemanticGraph:
    return SemanticGraph(
        parents={
            "concept:italy": ("hub:travel",),
            "concept:florence": ("concept:italy",),
            "concept:italian_food": ("concept:italy",),
            "concept:kpop": ("hub:music",),
            "concept:lesserafim": ("concept:kpop",),
        },
        labels={
            "hub:travel": "Travel",
            "hub:music": "Music",
            "concept:italy": "Italy",
            "concept:florence": "Florence",
            "concept:italian_food": "Italian food",
            "concept:kpop": "K-pop",
            "concept:lesserafim": "LE SSERAFIM",
        },
        associations=(
            CuratedAssociation(
                "concept:italian_food",
                "concept:florence",
                "concept:italy",
                semantic_cost=0.28,
            ),
        ),
    )


class SurfaceAssertionTests(unittest.TestCase):
    def test_typed_assertion_rejects_unbounded_scores_and_unknown_permissions(self) -> None:
        with self.assertRaises(ValueError):
            assertion("bad", "concept:x", "X", strength=float("nan"))
        with self.assertRaises(ValueError):
            assertion(
                "bad-permission",
                "concept:x",
                "X",
                permissions=frozenset({"send_raw_calendar"}),
            )

    def test_private_facts_are_not_public_facts(self) -> None:
        private = fact(
            "calendar-1",
            "AA 123 on 2027-01-03",
            group="calendar",
            private_calendar=True,
        )
        self.assertTrue(private.safe_for("memories"))
        self.assertFalse(private.safe_for("bio"))
        self.assertFalse(private.safe_for("icebreaker"))

    def test_healthkit_is_fitness_purpose_locked_and_requires_independent_grants(self) -> None:
        enabled = healthkit_fitness_surface_grants(
            fitness_matching_opt_in=True,
            bio_naming_opt_in=True,
            icebreaker_naming_opt_in=True,
            explanation_surfaces={"bio", "icebreaker"},
        )
        health_fact = fact(
            "health-running",
            "Runs regularly",
            group="fitness",
            grants=enabled,
            provider="healthkit",
            policy_locked=True,
            data_use_purpose="fitness_connection",
        )
        running = assertion(
            "running",
            "activity:running",
            "Running",
            predicate="routine",
            hub="hub:sports_movement",
            explicitness=Explicitness.CONFIRMED,
            groups=frozenset({"fitness"}),
            facts=(health_fact,),
            grants=enabled,
        )
        graph = SemanticGraph(labels={"activity:running": "Running"})
        general = DyadicMatcher(graph).match([running], [running])
        self.assertEqual(general.transported_mass, 0.0)
        fitness = DyadicMatcher(graph).match(
            [running],
            [running],
            data_use_purpose="fitness_connection",
        )
        self.assertGreater(fitness.transported_mass, 0.0)
        self.assertTrue(running.can_name("bio", "fitness_connection"))
        self.assertFalse(running.can_name("bio", "general_social"))
        inferred_running = assertion(
            "inferred-running",
            "activity:running",
            "Running",
            predicate="routine",
            hub="hub:sports_movement",
            explicitness=Explicitness.INFERRED,
            groups=frozenset({"fitness"}),
            facts=(health_fact,),
            grants=enabled,
        )
        self.assertTrue(
            inferred_running.can_select("bio", "fitness_connection")
        )
        self.assertFalse(
            inferred_running.can_name("bio", "fitness_connection")
        )

        disabled = healthkit_fitness_surface_grants(
            fitness_matching_opt_in=False,
            bio_naming_opt_in=True,
            icebreaker_naming_opt_in=True,
        )
        blocked_fact = fact(
            "health-running-blocked",
            "Runs regularly",
            group="fitness",
            grants=disabled,
            provider="healthkit",
            policy_locked=True,
            data_use_purpose="fitness_connection",
        )
        blocked = assertion(
            "blocked-running",
            "activity:running",
            "Running",
            predicate="routine",
            hub="hub:sports_movement",
            explicitness=Explicitness.CONFIRMED,
            groups=frozenset({"fitness"}),
            facts=(blocked_fact,),
            grants=disabled,
        )
        bilateral = DyadicMatcher(graph).match(
            [running],
            [blocked],
            data_use_purpose="fitness_connection",
        )
        self.assertEqual(bilateral.transported_mass, 0.0)
        self.assertTrue(blocked.can_name("bio", "fitness_connection"))
        self.assertTrue(blocked.can_name("icebreaker", "fitness_connection"))
        with self.assertRaises(ValueError):
            fact(
                "forged-health-general",
                "Runs regularly",
                group="fitness",
                provider="healthkit",
                policy_locked=False,
                data_use_purpose="general_social",
            )
        with self.assertRaises(ValueError):
            fact(
                "forged-health-group",
                "Runs regularly",
                group="music",
                provider="healthkit",
                policy_locked=True,
                data_use_purpose="fitness_connection",
            )
        for alias in ("Apple Health", "motion_fitness"):
            with self.assertRaises(ValueError):
                fact(
                    f"forged-{alias}",
                    "Runs regularly",
                    group="fitness",
                    provider=alias,
                    policy_locked=False,
                    data_use_purpose="general_social",
                )

    def test_selection_naming_and_explanation_are_independent_and_monotone(self) -> None:
        with self.assertRaises(ValueError):
            SurfaceGrant("bio", allow_selection=False, allow_naming=True)
        with self.assertRaises(ValueError):
            SurfaceGrant(
                "bio",
                allow_selection=True,
                allow_naming=False,
                allow_explanation=True,
            )

        support = fact("safe", "A detailed safe explanation")
        select_only = assertion(
            "select-only",
            "concept:x",
            "X",
            facts=(support,),
            grants=(SurfaceGrant("bio", allow_selection=True),),
        )
        self.assertTrue(select_only.can_select("bio"))
        self.assertFalse(select_only.can_name("bio"))
        self.assertFalse(select_only.can_explain("bio"))

        name_only = assertion(
            "name-only",
            "concept:x",
            "X",
            facts=(support,),
            grants=(
                SurfaceGrant(
                    "bio", allow_selection=True, allow_naming=True
                ),
            ),
        )
        self.assertTrue(name_only.can_name("bio"))
        self.assertFalse(name_only.can_explain("bio"))
        self.assertEqual(name_only.safe_facts("bio"), ())

        explain = assertion(
            "explain",
            "concept:x",
            "X",
            facts=(support,),
            grants=(
                SurfaceGrant(
                    "bio",
                    allow_selection=True,
                    allow_naming=True,
                    allow_explanation=True,
                ),
            ),
        )
        self.assertTrue(explain.permission("bio", PermissionUse.EXPLAIN))
        self.assertTrue(explain.can_explain("bio"))
        self.assertEqual(explain.safe_facts("bio"), (support,))

    def test_youtube_policy_lock_cannot_be_erased_by_user_confirmation(self) -> None:
        disabled_grants = youtube_policy_surface_grants(
            cross_source_fusion=False,
            bio_surface=True,
            icebreaker_surface=True,
        )
        youtube_fact = fact(
            "youtube-creator",
            "Subscribed to a resolved creator channel",
            grants=disabled_grants,
            provider="youtube",
            policy_locked=True,
        )
        confirmed = assertion(
            "confirmed-youtube",
            "concept:creator",
            "Creator",
            explicitness=Explicitness.CONFIRMED,
            facts=(youtube_fact,),
        )
        self.assertTrue(confirmed.can_name("memories"))
        self.assertFalse(confirmed.can_select("matching"))
        self.assertFalse(confirmed.can_name("bio"))
        self.assertFalse(confirmed.can_name("icebreaker"))

        enabled_grants = youtube_policy_surface_grants(
            cross_source_fusion=True,
            bio_surface=True,
            icebreaker_surface=False,
        )
        enabled_fact = fact(
            "youtube-enabled",
            "Resolved YouTube evidence",
            grants=enabled_grants,
            provider="youtube",
            policy_locked=True,
        )
        enabled = assertion(
            "enabled-youtube",
            "concept:creator",
            "Creator",
            explicitness=Explicitness.CONFIRMED,
            facts=(enabled_fact,),
        )
        self.assertTrue(enabled.can_select("matching"))
        self.assertTrue(enabled.can_name("bio"))
        self.assertFalse(enabled.can_explain("bio"))
        self.assertFalse(enabled.can_name("icebreaker"))

    def test_youtube_explanation_requires_its_own_policy_grant(self) -> None:
        grants = youtube_policy_surface_grants(
            cross_source_fusion=True,
            bio_surface=True,
            icebreaker_surface=False,
            explanation_surfaces={"bio"},
        )
        youtube_fact = fact(
            "youtube-explainable",
            "Follows the resolved official creator channel",
            grants=grants,
            provider="youtube",
            policy_locked=True,
        )
        item = assertion(
            "youtube-item",
            "concept:creator",
            "Creator",
            facts=(youtube_fact,),
            explicitness=Explicitness.CONFIRMED,
        )
        self.assertTrue(item.can_explain("bio"))
        self.assertEqual(item.safe_facts("bio"), (youtube_fact,))

    def test_independent_non_youtube_support_can_surface_without_policy_laundering(self) -> None:
        disabled = fact(
            "youtube-disabled",
            "YouTube evidence",
            grants=youtube_policy_surface_grants(
                cross_source_fusion=False,
                bio_surface=False,
                icebreaker_surface=False,
            ),
            provider="youtube",
            policy_locked=True,
        )
        independent = fact("explicit-independent", "User independently added Creator")
        item = assertion(
            "mixed-provenance",
            "concept:creator",
            "Creator",
            facts=(disabled, independent),
            explicitness=Explicitness.CONFIRMED,
        )
        self.assertTrue(item.can_name("bio"))
        self.assertNotIn(disabled, item.safe_facts("bio"))
        self.assertIn(independent, item.safe_facts("bio"))


class MemoriesTests(unittest.TestCase):
    def test_grouping_uses_parent_as_heading_but_does_not_double_count_mass(self) -> None:
        graph = base_graph()
        parent = assertion(
            "kpop",
            "concept:kpop",
            "K-pop",
            hub="hub:music",
            strength=0.60,
            information=0.45,
            specificity=0.45,
            mass=0.40,
        )
        child = assertion(
            "lesserafim",
            "concept:lesserafim",
            "LE SSERAFIM",
            hub="hub:music",
            strength=0.80,
            information=0.90,
            specificity=0.95,
            mass=0.40,
        )
        group = MemoriesOrganizer(graph).organize([parent, child])[0]
        self.assertEqual(group.summary_heading, "K-pop")
        self.assertEqual(
            tuple(item.key for item in group.representative_children),
            ("lesserafim",),
        )
        self.assertAlmostEqual(group.effective_mass, 0.40)
        self.assertEqual({item.key for item in group.editable_assertions}, {"kpop", "lesserafim"})

    def test_user_addition_is_favored_even_when_an_inference_is_stronger(self) -> None:
        graph = base_graph()
        user_parent = assertion(
            "user-kpop",
            "concept:kpop",
            "K-pop",
            hub="hub:music",
            strength=0.20,
            mapping=0.50,
            quality=0.50,
            explicitness=Explicitness.USER_ADDED,
            specificity=0.40,
            information=0.40,
        )
        inferred_child = assertion(
            "machine-artist",
            "concept:lesserafim",
            "LE SSERAFIM",
            hub="hub:music",
            strength=0.99,
            explicitness=Explicitness.INFERRED,
            specificity=0.95,
            information=0.95,
        )
        group = MemoriesOrganizer(graph).organize([inferred_child, user_parent])[0]
        self.assertEqual(group.representative_children[0].key, "user-kpop")
        self.assertEqual(group.summary_heading, "K-pop")

    def test_suppression_removes_only_the_exact_assertion(self) -> None:
        graph = base_graph()
        parent = assertion("kpop", "concept:kpop", "K-pop", hub="hub:music")
        child = assertion(
            "artist", "concept:lesserafim", "LE SSERAFIM", hub="hub:music"
        )
        organizer = MemoriesOrganizer(graph)
        group = organizer.organize(
            [parent, child], suppressed_assertion_keys={"artist"}
        )[0]
        self.assertEqual(tuple(item.key for item in group.editable_assertions), ("kpop",))
        restored = organizer.organize([parent, child])[0]
        self.assertEqual({item.key for item in restored.editable_assertions}, {"kpop", "artist"})

    def test_independent_parent_evidence_is_not_collapsed_with_child_family(self) -> None:
        graph = base_graph()
        parent = assertion(
            "independent-parent",
            "concept:kpop",
            "K-pop",
            hub="hub:music",
            mass=0.30,
            evidence_family="family:parent",
        )
        child = assertion(
            "child",
            "concept:lesserafim",
            "LE SSERAFIM",
            hub="hub:music",
            mass=0.40,
            evidence_family="family:child",
        )
        group = MemoriesOrganizer(graph).organize([parent, child])[0]
        self.assertEqual(
            {item.key for item in group.representative_children},
            {"independent-parent", "child"},
        )
        self.assertAlmostEqual(group.effective_mass, 0.70)

        family_suppressed = MemoriesOrganizer(graph).organize(
            [parent, child],
            suppressed_evidence_families={"family:child"},
        )[0]
        self.assertEqual(
            tuple(item.key for item in family_suppressed.editable_assertions),
            ("independent-parent",),
        )


class GraphCostTests(unittest.TestCase):
    def test_exact_parent_association_and_embedding_paths_are_distinct(self) -> None:
        graph = SemanticGraph(
            parents={"concept:child": ("concept:parent",)},
            associations=(
                CuratedAssociation("concept:a", "concept:b", "concept:bridge", 0.30),
            ),
            embedding_candidates={("concept:e1", "concept:e2"): 0.95},
        )
        exact = graph.cost(
            assertion("x1", "concept:x", "X"),
            assertion("x2", "concept:x", "X"),
        )
        parent = graph.cost(
            assertion("p", "concept:parent", "Parent"),
            assertion("c", "concept:child", "Child"),
        )
        association = graph.cost(
            assertion("a", "concept:a", "A"),
            assertion("b", "concept:b", "B"),
        )
        embedding = graph.cost(
            assertion("e1", "concept:e1", "E1"),
            assertion("e2", "concept:e2", "E2"),
        )
        self.assertEqual(exact.path_kind, "exact")
        self.assertEqual(parent.path_kind, "parent_child")
        self.assertEqual(association.path_kind, "curated_association")
        self.assertEqual(embedding.path_kind, "embedding_candidate")
        self.assertGreaterEqual(embedding.semantic, 0.25)
        self.assertEqual(association.bridge_concept, "concept:bridge")

    def test_relation_mismatch_penalizes_an_exact_concept_match(self) -> None:
        graph = base_graph()
        likes_left = assertion("left", "concept:italy", "Italy", predicate="likes")
        likes_right = assertion("right", "concept:italy", "Italy", predicate="likes")
        hometown = assertion(
            "home", "concept:italy", "Italy", predicate="hometown"
        )
        self.assertEqual(graph.cost(likes_left, likes_right).total, 0.0)
        mismatch = graph.cost(likes_left, hometown)
        self.assertGreater(mismatch.total, 0.0)
        self.assertLess(mismatch.relation_compatibility, 0.5)


class TransportTests(unittest.TestCase):
    def test_missing_sources_reduce_comparability_not_semantic_proximity(self) -> None:
        graph = base_graph()
        left = [assertion("l", "concept:italy", "Italy", groups=frozenset({"music"}))]
        right = [assertion("r", "concept:italy", "Italy", groups=frozenset({"music"}))]
        matcher = DyadicMatcher(graph)
        complete = matcher.match(left, right, expected_source_groups={"music"})
        missing = matcher.match(
            left,
            right,
            expected_source_groups={"music", "video", "calendar"},
        )
        self.assertAlmostEqual(complete.semantic_proximity, missing.semantic_proximity)
        self.assertLess(missing.comparability, complete.comparability)

    def test_relation_mismatch_reduces_transport_proximity(self) -> None:
        graph = base_graph()
        left = [assertion("l", "concept:italy", "Italy", predicate="likes")]
        like = [assertion("like", "concept:italy", "Italy", predicate="likes")]
        hometown = [
            assertion("home", "concept:italy", "Italy", predicate="hometown")
        ]
        matcher = DyadicMatcher(graph)
        like_result = matcher.match(left, like)
        home_result = matcher.match(left, hometown)
        self.assertGreater(like_result.semantic_proximity, home_result.semantic_proximity)

    def test_partial_transport_conserves_every_assertion_mass(self) -> None:
        graph = SemanticGraph(labels={"concept:a": "A", "concept:b": "B"})
        left = [
            assertion("la", "concept:a", "A", mass=0.60),
            assertion("lb", "concept:b", "B", mass=0.40),
        ]
        right = [
            assertion("ra", "concept:a", "A", mass=0.45),
            assertion("rb", "concept:b", "B", mass=0.20),
        ]
        result = DyadicMatcher(graph).match(left, right)
        left_caps = {item.key: item.mass for item in left}
        right_caps = {item.key: item.mass for item in right}
        for key, capacity in left_caps.items():
            used = sum(pair.mass for pair in result.pairs if pair.left_assertion_key == key)
            self.assertLessEqual(used, capacity + 1e-10)
        for key, capacity in right_caps.items():
            used = sum(pair.mass for pair in result.pairs if pair.right_assertion_key == key)
            self.assertLessEqual(used, capacity + 1e-10)
        self.assertLessEqual(result.transported_mass, min(1.0, 0.65) + 1e-10)
        self.assertAlmostEqual(
            result.left_unmatched_mass + result.transported_mass,
            result.left_total_mass,
        )
        self.assertAlmostEqual(
            result.right_unmatched_mass + result.transported_mass,
            result.right_total_mass,
        )
        self.assertTrue(all(math.isfinite(pair.mass) for pair in result.pairs))

    def test_disconnected_concepts_remain_unmatched(self) -> None:
        graph = SemanticGraph()
        result = DyadicMatcher(graph).match(
            [assertion("a", "concept:a", "A")],
            [assertion("b", "concept:b", "B")],
        )
        self.assertEqual(result.pairs, ())
        self.assertEqual(result.semantic_proximity, 0.0)
        self.assertEqual(result.comparability, 0.0)

    def test_parent_and_child_mass_are_not_both_transport_inputs(self) -> None:
        graph = base_graph()
        left = [
            assertion("parent", "concept:kpop", "K-pop", mass=0.50),
            assertion(
                "child",
                "concept:lesserafim",
                "LE SSERAFIM",
                specificity=0.95,
                information=0.95,
                mass=0.50,
            ),
        ]
        right = [
            assertion(
                "right-child",
                "concept:lesserafim",
                "LE SSERAFIM",
                specificity=0.95,
                information=0.95,
                mass=0.50,
            )
        ]
        result = DyadicMatcher(graph).match(left, right)
        self.assertAlmostEqual(result.left_total_mass, 0.50)
        self.assertTrue(all(pair.left_assertion_key == "child" for pair in result.pairs))

    def test_extreme_entropy_remains_numerically_finite(self) -> None:
        graph = base_graph()
        matcher = DyadicMatcher(
            graph,
            TransportConfig(entropy=1e-6, mass_relaxation=1e-4),
        )
        result = matcher.match(
            [assertion("l", "concept:italy", "Italy")],
            [assertion("r", "concept:italy", "Italy")],
        )
        self.assertTrue(math.isfinite(result.transported_mass))
        self.assertTrue(math.isfinite(result.semantic_proximity))


class BioTests(unittest.TestCase):
    def test_bio_may_select_without_naming_and_names_without_explaining(self) -> None:
        graph = SemanticGraph()
        private_selector = assertion(
            "selector",
            "concept:selector",
            "Selector",
            grants=(SurfaceGrant("bio", allow_selection=True),),
        )
        name_only = assertion(
            "name-only",
            "concept:name",
            "Safe concept label",
            facts=(fact("detail", "Do not reveal this supporting detail"),),
            grants=(
                SurfaceGrant("bio", allow_selection=True, allow_naming=True),
            ),
        )
        result = DirectionalBioSelector(graph, stable_clause_count=1).select(
            [],
            [private_selector, name_only],
            DyadicMatcher(graph).match([], []),
        )
        self.assertEqual(len(result.stable_facts), 1)
        self.assertEqual(result.stable_facts[0].assertion_key, "name-only")
        self.assertEqual(result.stable_facts[0].display_text, "Safe concept label")
        self.assertNotIn(
            "supporting detail",
            " ".join(item.display_text for item in result.all_facts),
        )

    def test_bio_keeps_two_stable_clauses_and_at_most_one_viewer_clause(self) -> None:
        graph = SemanticGraph(
            labels={
                "concept:a": "A",
                "concept:b": "B",
                "concept:c": "C",
                "concept:low": "Low",
            }
        )
        viewer = [assertion("viewer-c", "concept:c", "C", mass=0.40)]
        subject = [
            assertion("subject-a", "concept:a", "A", strength=0.98, mass=0.30),
            assertion("subject-b", "concept:b", "B", strength=0.95, mass=0.30),
            assertion("subject-c", "concept:c", "C", strength=0.80, mass=0.30),
            assertion(
                "subject-low",
                "concept:low",
                "Generic",
                strength=1.0,
                information=0.05,
                mass=0.10,
            ),
        ]
        transport = DyadicMatcher(graph).match(viewer, subject)
        selection = DirectionalBioSelector(
            graph, stable_clause_count=2, minimum_information_content=0.20
        ).select(viewer, subject, transport)
        self.assertEqual(len(selection.stable_facts), 2)
        self.assertEqual(
            {item.assertion_key for item in selection.stable_facts},
            {"subject-a", "subject-b"},
        )
        self.assertIsNotNone(selection.viewer_conditioned_fact)
        self.assertEqual(selection.viewer_conditioned_fact.assertion_key, "subject-c")  # type: ignore[union-attr]
        self.assertLessEqual(len(selection.all_facts), 3)
        self.assertNotIn("subject-low", {item.assertion_key for item in selection.all_facts})

    def test_unauthorized_inferred_private_calendar_fact_is_not_a_bio_clause(self) -> None:
        graph = SemanticGraph()
        private = assertion(
            "private",
            "concept:sample_city",
            "Sample City trip",
            predicate="past_travel_plan_to",
            explicitness=Explicitness.INFERRED,
            facts=(
                fact(
                    "flight",
                    "AA 123 on 2027-01-03",
                    group="calendar",
                    private_calendar=True,
                ),
            ),
        )
        selection = DirectionalBioSelector(graph).select([], [private], DyadicMatcher(graph).match([], []))
        self.assertEqual(selection.all_facts, ())


class IcebreakerTests(unittest.TestCase):
    def test_icebreaker_naming_permission_does_not_reveal_explanation(self) -> None:
        graph = base_graph()
        grants = (
            SurfaceGrant(
                "icebreaker", allow_selection=True, allow_naming=True
            ),
        )
        left = assertion(
            "left-name-only",
            "concept:italy",
            "Italy",
            facts=(fact("left-secret", "Private supporting explanation"),),
            grants=grants,
        )
        right = assertion(
            "right-name-only",
            "concept:italy",
            "Italy",
            facts=(fact("right-secret", "Another supporting explanation"),),
            grants=grants,
        )
        result = IcebreakerGenerator(graph).generate(
            [left], [right], right_person_name="Profile B"
        )
        self.assertIsNotNone(result)
        rendered = " ".join(
            (result.headline, result.left_fact, result.right_fact)  # type: ignore[union-attr]
        )
        self.assertNotIn("supporting explanation", rendered)
        self.assertIn("Italy", rendered)

    def test_specific_bridge_beats_generic_bridge(self) -> None:
        graph = base_graph()
        left = [
            assertion(
                "left-travel",
                "hub:travel",
                "Travel",
                specificity=0.15,
                information=0.10,
                mass=0.25,
            ),
            assertion(
                "left-italy",
                "concept:italy",
                "Italy",
                specificity=0.90,
                information=0.90,
                mass=0.25,
            ),
        ]
        right = [
            assertion(
                "right-travel",
                "hub:travel",
                "Travel",
                specificity=0.15,
                information=0.10,
                mass=0.25,
            ),
            assertion(
                "right-italy",
                "concept:italy",
                "Italy",
                specificity=0.90,
                information=0.90,
                mass=0.25,
            ),
        ]
        result = IcebreakerGenerator(
            graph, minimum_information_content=0.05
        ).generate(left, right, right_person_name="Profile B")
        self.assertIsNotNone(result)
        self.assertEqual(result.bridge_concept, "concept:italy")  # type: ignore[union-attr]

    def test_strong_explicit_affinity_licenses_both_like(self) -> None:
        graph = base_graph()
        result = IcebreakerGenerator(graph).generate(
            [assertion("left", "concept:italy", "Italy", predicate="likes")],
            [assertion("right", "concept:italy", "Italy", predicate="affinity_to")],
            right_person_name="Profile B",
        )
        self.assertIsNotNone(result)
        self.assertEqual(result.wording_license, WordingLicense.BOTH_LIKE)  # type: ignore[union-attr]
        self.assertEqual(result.headline, "You both like Italy.")  # type: ignore[union-attr]

    def test_related_but_differently_typed_facts_use_shared_thread(self) -> None:
        graph = base_graph()
        result = IcebreakerGenerator(graph).generate(
            [
                assertion(
                    "food",
                    "concept:italian_food",
                    "Italian food",
                    predicate="travel_interest",
                    facts=(fact("food-fact", "You like Italian food"),),
                )
            ],
            [
                assertion(
                    "florence",
                    "concept:florence",
                    "Florence",
                    predicate="returns_to",
                    facts=(fact("florence-fact", "Profile B often returns to Florence"),),
                )
            ],
            right_person_name="Profile B",
        )
        self.assertIsNotNone(result)
        self.assertEqual(result.wording_license, WordingLicense.SHARED_THREAD)  # type: ignore[union-attr]
        self.assertEqual(result.headline, "Italy looks like a shared thread.")  # type: ignore[union-attr]

    def test_weak_or_embedding_only_evidence_uses_conversation_topic(self) -> None:
        graph = SemanticGraph(
            labels={"concept:bridge": "Cinema"},
            associations=(
                CuratedAssociation("concept:a", "concept:b", "concept:bridge", 0.30),
            ),
        )
        result = IcebreakerGenerator(graph).generate(
            [
                assertion(
                    "a",
                    "concept:a",
                    "A",
                    strength=0.30,
                    mapping=0.55,
                    quality=0.55,
                    explicitness=Explicitness.INFERRED,
                    facts=(fact("a-safe", "You watched A"),),
                )
            ],
            [
                assertion(
                    "b",
                    "concept:b",
                    "B",
                    strength=0.35,
                    mapping=0.55,
                    quality=0.55,
                    explicitness=Explicitness.INFERRED,
                    facts=(fact("b-safe", "Profile B watched B"),),
                )
            ],
            right_person_name="Profile B",
        )
        self.assertIsNotNone(result)
        self.assertEqual(result.wording_license, WordingLicense.CONVERSATION_TOPIC)  # type: ignore[union-attr]

    def test_raw_future_and_private_calendar_evidence_never_leaks(self) -> None:
        graph = base_graph()
        private_text = "AA 123 on 2027-01-03 from the private calendar"
        unsafe = fact(
            "private-flight",
            private_text,
            group="calendar",
            raw=True,
            future=True,
            private_calendar=True,
        )
        inferred = assertion(
            "future-trip",
            "concept:italy",
            "Italy",
            predicate="scheduled_travel_to",
            explicitness=Explicitness.INFERRED,
            facts=(unsafe,),
        )
        other = assertion("other", "concept:italy", "Italy")
        self.assertIsNone(
            IcebreakerGenerator(graph).generate(
                [inferred], [other], right_person_name="Profile B"
            )
        )

        # A confirmed, separately permitted semantic assertion can be named,
        # but the unsafe provenance string is never selected as support text.
        confirmed = assertion(
            "confirmed",
            "concept:italy",
            "Italy",
            predicate="visited",
            explicitness=Explicitness.CONFIRMED,
            facts=(unsafe,),
        )
        result = IcebreakerGenerator(graph).generate(
            [confirmed],
            [
                assertion(
                    "travel-interest",
                    "concept:italy",
                    "Italy",
                    predicate="travel_interest",
                )
            ],
            right_person_name="Profile B",
        )
        self.assertIsNotNone(result)
        rendered = " ".join(
            (result.headline, result.left_fact, result.right_fact)  # type: ignore[union-attr]
        )
        self.assertNotIn(private_text, rendered)
        self.assertNotIn("2027-01-03", rendered)

    def test_surface_permission_is_required_on_both_sides(self) -> None:
        graph = base_graph()
        hidden = assertion(
            "hidden",
            "concept:italy",
            "Italy",
            permissions=frozenset({"memories", "matching"}),
        )
        visible = assertion("visible", "concept:italy", "Italy")
        self.assertIsNone(
            IcebreakerGenerator(graph).generate(
                [hidden], [visible], right_person_name="Profile B"
            )
        )


if __name__ == "__main__":
    unittest.main()
