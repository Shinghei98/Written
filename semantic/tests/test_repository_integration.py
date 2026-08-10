import json
import hashlib
import os
import re
import subprocess
import tomllib
import unittest
from pathlib import Path

import written_ontology


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "integration" / "written_repository_baseline.json"


class RepositoryIntegrationManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        configured_repo = os.environ.get("WRITTEN_REPOSITORY_PATH")
        cls.repository_path = Path(configured_repo).resolve() if configured_repo else None

    def test_package_versions_are_consistent(self) -> None:
        pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
        expected = self.manifest["package_version"]
        self.assertEqual(pyproject["project"]["version"], expected)
        self.assertEqual(written_ontology.__version__, expected)

    def test_reviewed_repository_baseline_is_explicit(self) -> None:
        repository = self.manifest["repository"]
        self.assertEqual(repository["owner"], "Shinghei98")
        self.assertEqual(repository["name"], "Written")
        self.assertRegex(repository["commit"], r"^[0-9a-f]{40}$")
        self.assertEqual(
            repository["commit"], "8203353532dffd5f608df92861fd8a631dc7b7d4"
        )
        self.assertRegex(repository["migration_head"], r"^\d{4}_[a-z0-9_]+\.sql$")
        self.assertEqual(self.manifest["authority"], "target_architecture")

    def test_reference_migrations_exist_in_package(self) -> None:
        for relative_path in self.manifest["reference_migrations"]:
            with self.subTest(relative_path=relative_path):
                self.assertTrue((ROOT / relative_path).is_file())
        self.assertEqual(
            self.manifest["reference_migrations"][-1],
            "sql/006_current_state_and_surface_hardening.sql",
        )
        for relative_path in (
            "sql/tests/006_current_state_and_surface_hardening_contract.sql",
            "sql/tests/fixtures/005_surface_fact_upgrade_fixture.sql",
            "sql/tests/006_surface_fact_upgrade_contract.sql",
        ):
            with self.subTest(relative_path=relative_path):
                self.assertTrue((ROOT / relative_path).is_file())

    def test_configured_written_checkout_matches_reviewed_evidence(self) -> None:
        if self.repository_path is None:
            self.skipTest("set WRITTEN_REPOSITORY_PATH for checkout verification")
        self.assertTrue((self.repository_path / ".git").exists())
        completed = subprocess.run(
            ["git", "-C", str(self.repository_path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            completed.stdout.strip(), self.manifest["repository"]["commit"]
        )
        migration_names = sorted(
            path.name
            for path in (self.repository_path / "supabase/migrations").glob("*.sql")
        )
        self.assertTrue(migration_names)
        self.assertEqual(
            migration_names[-1], self.manifest["repository"]["migration_head"]
        )
        for relative_path, expected_digest in self.manifest[
            "repository_verification"
        ]["verified_files_sha256"].items():
            with self.subTest(relative_path=relative_path):
                payload = (self.repository_path / relative_path).read_bytes()
                self.assertEqual(hashlib.sha256(payload).hexdigest(), expected_digest)

    def test_application_migration_plan_is_contiguous_and_named(self) -> None:
        migrations = self.manifest["application_migrations"]
        sequences = [migration["sequence"] for migration in migrations]
        self.assertEqual(sequences, list(range(42, 51)))
        self.assertEqual(migrations[-1]["suggested_name"], "0050_semantic_cutover.sql")
        for migration in migrations:
            expected_prefix = f"{migration['sequence']:04d}_"
            self.assertTrue(migration["suggested_name"].startswith(expected_prefix))
            self.assertTrue(migration["suggested_name"].endswith(".sql"))
            self.assertTrue(re.fullmatch(r"[a-z0-9_]+", migration["role"]))

    def test_repository_path_decisions_do_not_overlap(self) -> None:
        decisions = self.manifest["repository_paths"]
        sets = {name: set(paths) for name, paths in decisions.items()}
        for name, paths in sets.items():
            self.assertTrue(paths, name)
        names = list(sets)
        for index, left in enumerate(names):
            for right in names[index + 1 :]:
                self.assertFalse(sets[left] & sets[right], f"{left} overlaps {right}")

    def test_cutover_is_additive_before_retirement(self) -> None:
        phases = self.manifest["cutover_phases"]
        self.assertEqual(phases[0], "baseline_and_native_dry_run")
        self.assertLess(
            phases.index("private_ingestion_and_dual_write"),
            phases.index("legacy_semantic_retirement"),
        )
        self.assertLess(
            phases.index("backfill_and_shadow_compute"),
            phases.index("server_owned_discovery_and_profiles"),
        )


if __name__ == "__main__":
    unittest.main()
