from __future__ import annotations

import dataclasses
import unittest

from written_ontology.granularity import (
    AdditionMode,
    AdditionRelation,
    AssertionOrigin,
    ConceptHierarchy,
    SuggestionCandidate,
    SuggestionKind,
    accept_suggestion,
    attach_suggestions,
    build_resolution_assertions,
    create_canonical_addition,
    create_free_text_addition,
    learning_effects,
    project_resolution_to_surface,
    relation_allowed_for_origin,
    remove_displayed_assertion,
    visible_resolution_assertions,
)
from written_ontology.surfaces import PermissionUse, SurfaceGrant


def cuisine_hierarchy() -> ConceptHierarchy:
    return ConceptHierarchy(
        parents={
            "concept:tuscan_trattorias": ("concept:italian_cuisine",),
            "concept:italian_cuisine": ("concept:italy",),
        },
        labels={
            "concept:tuscan_trattorias": "Tuscan trattorias",
            "concept:italian_cuisine": "Italian cuisine",
            "concept:italy": "Italy",
        },
    )


class UpwardPropagationTests(unittest.TestCase):
    def test_tuscan_trattorias_propagates_to_cuisine_then_italy_upward_only(self) -> None:
        addition = create_canonical_addition(
            addition_id="tuscan",
            exact_phrase="Tuscan trattorias",
            concept_kind="cuisine",
            canonical_concept_key="concept:tuscan_trattorias",
            canonical_label="Tuscan trattorias",
            relation=AdditionRelation.LIKES,
            canonical_mapping_confidence=0.95,
            surface_permissions={"memories", "matching"},
        )
        views = build_resolution_assertions(
            addition, cuisine_hierarchy(), attenuation=0.50
        )
        self.assertEqual(
            tuple(item.concept_key for item in views),
            (
                "concept:tuscan_trattorias",
                "concept:italian_cuisine",
                "concept:italy",
            ),
        )
        self.assertEqual(tuple(item.depth for item in views), (0, 1, 2))
        self.assertEqual(views[0].exact_phrase, "Tuscan trattorias")
        self.assertEqual(views[0].label, "Tuscan trattorias")
        self.assertGreater(
            views[0].canonical_mapping_confidence,
            views[1].canonical_mapping_confidence,
        )
        self.assertGreater(
            views[1].canonical_mapping_confidence,
            views[2].canonical_mapping_confidence,
        )
        self.assertEqual({item.evidence_family for item in views}, {addition.evidence_family})

    def test_broad_italy_addition_never_creates_children(self) -> None:
        addition = create_canonical_addition(
            addition_id="italy",
            exact_phrase="Italy",
            concept_kind="place",
            canonical_concept_key="concept:italy",
            canonical_label="Italy",
        )
        views = build_resolution_assertions(addition, cuisine_hierarchy())
        self.assertEqual(tuple(item.concept_key for item in views), ("concept:italy",))
        self.assertNotIn(
            "concept:italian_cuisine", {item.concept_key for item in views}
        )
        self.assertNotIn(
            "concept:tuscan_trattorias", {item.concept_key for item in views}
        )

    def test_branching_dag_conserves_mass_instead_of_making_votes(self) -> None:
        hierarchy = ConceptHierarchy(
            parents={
                "concept:leaf": ("concept:left_parent", "concept:right_parent"),
                "concept:left_parent": ("concept:root",),
                "concept:right_parent": ("concept:root",),
            }
        )
        addition = create_canonical_addition(
            addition_id="branch",
            exact_phrase="Leaf",
            concept_kind="topic",
            canonical_concept_key="concept:leaf",
            canonical_label="Leaf",
            mass=0.80,
        )
        views = build_resolution_assertions(addition, hierarchy, attenuation=0.60)
        self.assertAlmostEqual(sum(item.mass for item in views), 0.80)
        self.assertEqual({item.evidence_family for item in views}, {addition.evidence_family})
        depth_one = [item for item in views if item.depth == 1]
        self.assertEqual(len(depth_one), 2)
        self.assertAlmostEqual(depth_one[0].mass, depth_one[1].mass)
        self.assertTrue(all(item.propagation_weight <= 1.0 for item in views))


class AdditionContractTests(unittest.TestCase):
    def test_addition_grants_propagate_to_every_resolution_view(self) -> None:
        grants = (
            SurfaceGrant("memories", allow_selection=True, allow_naming=True),
            SurfaceGrant("matching", allow_selection=True),
        )
        addition = create_canonical_addition(
            addition_id="permissioned",
            exact_phrase="Tuscan trattorias",
            concept_kind="cuisine",
            canonical_concept_key="concept:tuscan_trattorias",
            canonical_label="Tuscan trattorias",
            surface_permissions=(),
            surface_grants=grants,
        )
        views = build_resolution_assertions(addition, cuisine_hierarchy())
        self.assertTrue(all(item.permission("matching", PermissionUse.SELECT) for item in views))
        self.assertTrue(all(not item.permission("matching", PermissionUse.NAME) for item in views))
        self.assertTrue(all(item.permission("memories", PermissionUse.NAME) for item in views))
        self.assertEqual(
            visible_resolution_assertions(views, (), surface="matching"), ()
        )
        self.assertEqual(
            len(visible_resolution_assertions(views, (), surface="memories")),
            len(views),
        )

        projected = project_resolution_to_surface(
            views[0],
            hub_key="hub:food",
            specificity=0.90,
            information_content=0.85,
        )
        self.assertEqual(projected.evidence_family, addition.evidence_family)
        self.assertEqual(projected.mass, views[0].mass)
        self.assertTrue(projected.can_select("matching"))
        self.assertFalse(projected.can_name("matching"))
        self.assertTrue(projected.can_name("memories"))

    def test_free_text_phrase_and_uncertainty_remain_separate(self) -> None:
        exact = "  Tuscan trattorias—late-night  "
        suggestion = SuggestionCandidate(
            concept_key="concept:tuscan_trattorias",
            label="Tuscan trattorias",
            kind=SuggestionKind.CANONICAL,
            canonical_mapping_confidence=0.74,
            method="embedding_candidate",
        )
        addition = create_free_text_addition(
            addition_id="free",
            exact_phrase=exact,
            concept_kind="cuisine",
            selection_confidence=0.98,
            suggestions=(suggestion,),
        )
        self.assertEqual(addition.exact_phrase, exact)
        self.assertEqual(addition.explicitness, 1.0)
        self.assertEqual(addition.selection_confidence, 0.98)
        self.assertEqual(addition.canonical_mapping_confidence, 0.0)
        self.assertIsNone(addition.canonical_concept_key)
        local_view = build_resolution_assertions(addition, cuisine_hierarchy())
        self.assertEqual(len(local_view), 1)
        self.assertEqual(local_view[0].label, exact)
        self.assertIsNone(local_view[0].concept_key)

    def test_suggestions_do_not_remap_until_the_user_accepts_one(self) -> None:
        addition = create_free_text_addition(
            addition_id="unmapped",
            exact_phrase="Tuscan spots",
            concept_kind="cuisine",
        )
        suggestion = SuggestionCandidate(
            concept_key="concept:tuscan_trattorias",
            label="Tuscan trattorias",
            kind=SuggestionKind.CANONICAL,
            canonical_mapping_confidence=0.82,
            method="curated_alias_candidate",
        )
        proposed = attach_suggestions(addition, [suggestion])
        self.assertEqual(proposed.mode, AdditionMode.FREE_TEXT)
        self.assertIsNone(proposed.canonical_concept_key)
        accepted = accept_suggestion(proposed, "concept:tuscan_trattorias")
        self.assertEqual(accepted.mode, AdditionMode.CANONICAL_SELECTION)
        self.assertEqual(accepted.canonical_concept_key, "concept:tuscan_trattorias")
        self.assertEqual(accepted.canonical_mapping_confidence, 0.82)
        self.assertEqual(accepted.exact_phrase, "Tuscan spots")
        self.assertEqual(accepted.evidence_family, addition.evidence_family)

    def test_bare_place_uses_neutral_explicit_association(self) -> None:
        bare = create_canonical_addition(
            addition_id="bare-place",
            exact_phrase="Sample City",
            concept_kind="place",
            canonical_concept_key="place:sample_city",
            canonical_label="Sample City",
        )
        self.assertEqual(
            bare.relation, AdditionRelation.EXPLICIT_ASSOCIATION_WITH
        )
        self.assertNotEqual(bare.relation, AdditionRelation.HOMETOWN)
        self.assertNotEqual(bare.relation, AdditionRelation.VISITED)

    def test_relation_specific_additions_remain_distinct(self) -> None:
        common = dict(
            exact_phrase="Sample City",
            concept_kind="place",
            canonical_concept_key="place:sample_city",
            canonical_label="Sample City",
        )
        hometown = create_canonical_addition(
            addition_id="home", relation="hometown", **common
        )
        visited = create_canonical_addition(
            addition_id="visited", relation="visited", **common
        )
        travel = create_canonical_addition(
            addition_id="travel", relation="travel_interest", **common
        )
        self.assertEqual(
            {hometown.relation, visited.relation, travel.relation},
            {
                AdditionRelation.HOMETOWN,
                AdditionRelation.VISITED,
                AdditionRelation.TRAVEL_INTEREST,
            },
        )

    def test_hometown_is_licensed_only_by_an_explicit_user_addition(self) -> None:
        self.assertTrue(
            relation_allowed_for_origin("hometown", AssertionOrigin.USER_ADDED)
        )
        self.assertFalse(
            relation_allowed_for_origin("hometown", AssertionOrigin.INFERRED)
        )
        self.assertFalse(
            relation_allowed_for_origin("hometown", AssertionOrigin.CONFIRMED)
        )
        self.assertTrue(
            relation_allowed_for_origin("travel_interest", AssertionOrigin.INFERRED)
        )


class LearningTests(unittest.TestCase):
    def test_linked_canonical_addition_can_create_mapping_positive_label(self) -> None:
        linked = create_canonical_addition(
            addition_id="linked",
            exact_phrase="Tuscan trattorias",
            concept_kind="cuisine",
            canonical_concept_key="concept:tuscan_trattorias",
            canonical_label="Tuscan trattorias",
            linked_observation_ids=("obs-1",),
        )
        effect = learning_effects(
            linked, validated_linked_observation_ids=("obs-1",)
        )
        self.assertTrue(effect.user_affinity_positive)
        self.assertEqual(len(effect.mapping_positive_labels), 1)
        self.assertEqual(
            effect.mapping_positive_labels[0].concept_key,
            "concept:tuscan_trattorias",
        )
        self.assertFalse(effect.semantic_global_negative)

    def test_unlinked_or_unmapped_addition_does_not_label_mapping(self) -> None:
        unlinked = create_canonical_addition(
            addition_id="unlinked",
            exact_phrase="Tuscan trattorias",
            concept_kind="cuisine",
            canonical_concept_key="concept:tuscan_trattorias",
            canonical_label="Tuscan trattorias",
        )
        self.assertEqual(learning_effects(unlinked).mapping_positive_labels, ())

        unmapped = create_free_text_addition(
            addition_id="unmapped-linked",
            exact_phrase="Tuscan-ish places",
            concept_kind="cuisine",
            linked_observation_ids=("obs-2",),
        )
        self.assertEqual(
            learning_effects(
                unmapped, validated_linked_observation_ids=("obs-2",)
            ).mapping_positive_labels,
            (),
        )

    def test_validator_cannot_attach_someone_elses_observation(self) -> None:
        linked = create_canonical_addition(
            addition_id="linked-validation",
            exact_phrase="Italy",
            concept_kind="place",
            canonical_concept_key="concept:italy",
            canonical_label="Italy",
            linked_observation_ids=("owned",),
        )
        with self.assertRaises(ValueError):
            learning_effects(
                linked, validated_linked_observation_ids=("not-owned",)
            )


class RemovalTests(unittest.TestCase):
    def test_child_removal_suppresses_its_family_not_independent_parent_evidence(self) -> None:
        hierarchy = cuisine_hierarchy()
        child_addition = create_canonical_addition(
            addition_id="child-addition",
            exact_phrase="Tuscan trattorias",
            concept_kind="cuisine",
            canonical_concept_key="concept:tuscan_trattorias",
            canonical_label="Tuscan trattorias",
            relation="likes",
            surface_permissions={"memories", "matching"},
        )
        parent_addition = create_canonical_addition(
            addition_id="independent-parent",
            exact_phrase="Italian cuisine",
            concept_kind="cuisine",
            canonical_concept_key="concept:italian_cuisine",
            canonical_label="Italian cuisine",
            relation="likes",
            surface_permissions={"memories", "matching"},
        )
        child_views = build_resolution_assertions(child_addition, hierarchy)
        parent_views = build_resolution_assertions(parent_addition, hierarchy)
        removal = remove_displayed_assertion(
            child_views[0], surface="memories", client_event_id="remove-1"
        )
        visible = visible_resolution_assertions(
            (*child_views, *parent_views),
            [removal.suppression],
            surface="memories",
        )
        self.assertNotIn(
            child_addition.evidence_family, {item.evidence_family for item in visible}
        )
        self.assertIn(
            parent_addition.evidence_family, {item.evidence_family for item in visible}
        )
        self.assertIn(
            "concept:italian_cuisine", {item.concept_key for item in visible}
        )

        # The same family remains available on another permitted surface.
        matching_visible = visible_resolution_assertions(
            (*child_views, *parent_views),
            [removal.suppression],
            surface="matching",
        )
        self.assertIn(
            child_addition.evidence_family,
            {item.evidence_family for item in matching_visible},
        )

    def test_removal_has_no_reason_dislike_false_or_global_mapping_effect(self) -> None:
        addition = create_free_text_addition(
            addition_id="remove-free",
            exact_phrase="My phrase",
            concept_kind="topic",
        )
        view = build_resolution_assertions(addition, cuisine_hierarchy())[0]
        effects = remove_displayed_assertion(
            view, surface="memories", client_event_id="remove-free-1"
        )
        self.assertFalse(effects.semantic_global_negative)
        self.assertFalse(effects.creates_dislike)
        self.assertFalse(effects.creates_false_label)
        self.assertEqual(effects.mapping_negative_labels, ())
        self.assertNotIn(
            "reason", {item.name for item in dataclasses.fields(type(effects.suppression))}
        )


if __name__ == "__main__":
    unittest.main()
