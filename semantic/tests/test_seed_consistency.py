from __future__ import annotations

import re
import unittest
from dataclasses import replace
from pathlib import Path

from written_ontology.seed_consistency import (
    INTENTIONAL_SQL_ONLY_SEED_TABLES,
    SEMANTIC_PRIVATE_SCHEMA,
    SeedCatalog,
    audit_seed_files,
    compare_seed_catalogs,
    load_csv_seed_catalog,
    load_sql_seed_catalog,
)


ROOT = Path(__file__).resolve().parents[1]
SEED_DIR = ROOT / "ontology"
# **The seed under audit is the app's migration, not the reference file.** The
# reference `sql/003_seed.sql` is deliberately not vendored — its adapted form
# is `0044_semantic_seed.sql`, and keeping both would be two divergent copies of
# one catalog. This is the whole reason the package is in-repo rather than
# beside it: out of repo this path would be a pinned external checkout that goes
# stale silently.
#
# The parser survives the move untouched because it anchors on the CTE names
# `seed`, `revision_seed`, `label_seed` and `edge_seed`, all of which the
# adaptation preserved verbatim.
SQL_SEED = ROOT.parent / "supabase" / "migrations" / "0044_semantic_seed.sql"


class SeedConsistencyTests(unittest.TestCase):
    def test_csv_and_sql_shared_ontology_seeds_are_exactly_identical(self) -> None:
        differences = audit_seed_files(SEED_DIR, SQL_SEED)
        detail = "\n".join(str(item) for item in differences)
        self.assertEqual(differences, (), detail)

    def test_contract_covers_concepts_aliases_edges_and_policies(self) -> None:
        csv_catalog = load_csv_seed_catalog(SEED_DIR)
        sql_catalog = load_sql_seed_catalog(SQL_SEED)

        self.assertEqual(len(csv_catalog.concepts), 45)
        self.assertEqual(len(csv_catalog.aliases), 42)
        self.assertEqual(len(csv_catalog.edges), 37)
        self.assertEqual(csv_catalog, sql_catalog)
        self.assertEqual(
            {item.inference_policy for item in csv_catalog.concepts},
            {"inferable", "review_required", "explicit_only"},
        )
        self.assertIn(
            ("identity", "sensitive", "explicit_only", "blocked"),
            {
                (
                    item.concept_kind,
                    item.sensitivity,
                    item.inference_policy,
                    item.status,
                )
                for item in csv_catalog.concepts
            },
        )
        self.assertIn(
            "supports_cultural_affinity_candidate",
            {item.predicate_key for item in csv_catalog.edges},
        )
        sports = next(
            item
            for item in csv_catalog.concepts
            if item.concept_key == "hub:sports_movement"
        )
        self.assertEqual(
            sports.definition,
            "Purpose-limited fitness evidence, including reviewed "
            "HealthKit-derived routines when consent and coverage gates pass.",
        )
        fitness_keys = {
            item.concept_key
            for item in csv_catalog.concepts
            if item.concept_key.startswith(("activity:", "routine:"))
        }
        self.assertEqual(len(fitness_keys), 24)
        self.assertTrue(
            all(
                item.inference_policy == "review_required"
                for item in csv_catalog.concepts
                if item.concept_key in fitness_keys
            )
        )
        self.assertEqual(
            {
                item.subject_key
                for item in csv_catalog.edges
                if item.subject_key in fitness_keys and item.predicate_key == "broader"
            },
            fitness_keys,
        )

    def test_drift_report_identifies_the_exact_changed_field(self) -> None:
        csv_catalog = load_csv_seed_catalog(SEED_DIR)
        sql_catalog = load_sql_seed_catalog(SQL_SEED)
        original = sql_catalog.concepts[0]
        changed = replace(original, inference_policy="inferable")
        if changed == original:
            changed = replace(original, inference_policy="review_required")
        mutated = SeedCatalog(
            declared_concept_keys=sql_catalog.declared_concept_keys,
            concepts=tuple(
                changed if item.concept_key == original.concept_key else item
                for item in sql_catalog.concepts
            ),
            aliases=sql_catalog.aliases,
            edges=sql_catalog.edges,
        )

        differences = compare_seed_catalogs(csv_catalog, mutated)
        self.assertEqual(len(differences), 1)
        self.assertEqual(differences[0].section, "concepts")
        self.assertEqual(differences[0].item_key, repr(original.concept_key))
        self.assertEqual(differences[0].field, "inference_policy")

    def test_sql_only_configuration_boundary_is_explicit_and_preserved(self) -> None:
        sql = SQL_SEED.read_text(encoding="utf-8")
        self.assertEqual(
            INTENTIONAL_SQL_ONLY_SEED_TABLES,
            (
                "ontology.relation_types",
                f"{SEMANTIC_PRIVATE_SCHEMA}.sources",
                "ontology.versions",
                "ontology.model_versions",
                "ontology.embedding_models",
                "ontology.motif_rules",
            ),
        )
        for table in INTENTIONAL_SQL_ONLY_SEED_TABLES:
            with self.subTest(table=table):
                self.assertRegex(
                    sql,
                    re.compile(
                        rf"\binsert\s+into\s+{re.escape(table)}\b",
                        re.IGNORECASE,
                    ),
                )

    def test_healthkit_bootstrap_is_inactive_until_migration_005(self) -> None:
        sql = SQL_SEED.read_text(encoding="utf-8")
        self.assertRegex(
            sql,
            re.compile(
                r"\('healthkit',\s*'apple',\s*'movement',\s*'movement',"
                r"\s*'not_applicable',\s*0\.90,\s*"
                r"'\{\"activity_day\":0\.0,\"activity_hour\":0\.0,"
                r"\"completed_activity\":0\.0,"
                r"\"accelerometer_sample\":0\.0\}'::jsonb\)",
                re.IGNORECASE | re.DOTALL,
            ),
        )
        self.assertRegex(
            sql,
            re.compile(
                rf"update\s+{re.escape(SEMANTIC_PRIVATE_SCHEMA)}\.sources"
                r"\s+set\s+active\s*=\s*false"
                r"\s+where\s+source_code\s*=\s*'healthkit'",
                re.IGNORECASE,
            ),
        )
        self.assertIn(
            "Migration 005 activates the source only",
            sql,
        )

    def test_sql_literal_parser_preserves_commas_case_and_definition_text(self) -> None:
        catalog = load_sql_seed_catalog(SQL_SEED)
        film = next(
            item for item in catalog.concepts if item.concept_key == "hub:film_video"
        )
        italy_alias = next(
            item
            for item in catalog.aliases
            if item.concept_key == "place:italy" and item.alias_type == "preferred"
        )
        self.assertEqual(film.preferred_label, "Film, TV & video")
        self.assertEqual(film.definition, "Provisional fixed hub.")
        self.assertEqual(italy_alias.alias, "Italy")
        sleep = next(
            item
            for item in catalog.concepts
            if item.concept_key == "routine:consistent_sleep_schedule"
        )
        self.assertEqual(sleep.inference_policy, "review_required")
        self.assertEqual(
            sleep.definition,
            "Coarse wellness routine; never sleep quality or diagnosis.",
        )


if __name__ == "__main__":
    unittest.main()
