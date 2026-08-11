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

    def test_adapted_application_migrations_exist_in_repository(self) -> None:
        """The reference `sql/` tree is not vendored; its adapted form is.

        Upstream this asserted that `sql/001…006` were present in the package.
        In this repository they deliberately are not: copying them alongside
        their adaptations would be two divergent copies of ten thousand lines
        of the same DDL, which the integration contract names as a failure.
        What must exist instead are the app migrations they became.
        """
        migrations = ROOT.parent / "supabase" / "migrations"
        applied = self.manifest["application_migrations_applied"]
        by_sequence = {
            item["sequence"]: item["suggested_name"]
            for item in self.manifest["application_migrations"]
        }
        for sequence in applied:
            name = by_sequence[sequence]
            with self.subTest(migration=name):
                self.assertTrue((migrations / name).is_file(), f"{name} is missing")
        # Keyed off role, not name. Migration numbers shift — 0049 was spent on
        # captured platform drift and pushed projections and cutover up one —
        # and a hardcoded filename here is the same self-referential pin this
        # class was rewritten to stop being.
        by_role = {item["role"]: item for item in self.manifest["application_migrations"]}
        self.assertIn("adapt_reference_006", by_role)
        self.assertIn(by_role["adapt_reference_006"]["sequence"], applied)
        # The reference chain is recorded as history and must stay recorded,
        # but nothing may look for those files on disk any more.
        self.assertEqual(len(self.manifest["reference_migrations"]), 6)
        for relative_path in self.manifest["reference_migrations"]:
            with self.subTest(relative_path=relative_path):
                self.assertFalse(
                    (ROOT / relative_path).exists(),
                    f"{relative_path} was vendored; it should not be",
                )

    def test_configured_written_checkout_descends_from_reviewed_evidence(self) -> None:
        """A baseline, not a pin.

        Upstream this asserted `HEAD == repository.commit` and
        `migration_head == 0041_collaborator.sql`. Once the package lives
        *inside* the repository it describes, that is self-referential: it goes
        red on the next commit anybody makes, which trains people to ignore it.

        What is actually worth asserting is that the checkout has not diverged
        from what v0.3.1 reviewed — the reviewed commit is still an ancestor,
        and the migration head has only moved forward.
        """
        if self.repository_path is None:
            self.skipTest("set WRITTEN_REPOSITORY_PATH for checkout verification")
        self.assertTrue((self.repository_path / ".git").exists())
        reviewed = self.manifest["repository"]["commit"]
        descends = subprocess.run(
            ["git", "-C", str(self.repository_path),
             "merge-base", "--is-ancestor", reviewed, "HEAD"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            descends.returncode,
            0,
            f"reviewed commit {reviewed} is not an ancestor of HEAD — either the "
            f"history was rewritten or this is a different repository "
            f"(a shallow clone also fails here; fetch with depth 0)",
        )
        migration_names = sorted(
            path.name
            for path in (self.repository_path / "supabase/migrations").glob("*.sql")
        )
        self.assertTrue(migration_names)
        self.assertGreaterEqual(
            migration_names[-1],
            self.manifest["repository"]["migration_head"],
            "migration head moved backwards from the reviewed baseline",
        )

    def test_reviewed_swift_and_sql_seams_report_their_drift(self) -> None:
        """A drift report over the seams the contract calls adapt-or-replace.

        These eight files are where the application and the semantic system
        meet. A digest change is not a failure in itself — it is a signal that
        the application side moved and somebody should decide whether the
        semantic side must follow. Knowing movement is recorded in
        `accepted_drift_sha256` with a reason; anything else is reported by
        name, because a stale pin nobody updates says nothing at all.
        """
        if self.repository_path is None:
            self.skipTest("set WRITTEN_REPOSITORY_PATH for checkout verification")
        verification = self.manifest["repository_verification"]
        reviewed = verification["verified_files_sha256"]
        accepted = verification.get("accepted_drift_sha256", {})
        unexplained: list[str] = []
        for relative_path, reviewed_digest in reviewed.items():
            payload = (self.repository_path / relative_path).read_bytes()
            actual = hashlib.sha256(payload).hexdigest()
            if actual == reviewed_digest:
                continue
            allowed = accepted.get(relative_path, {}).get("sha256")
            if actual == allowed:
                continue
            unexplained.append(
                f"  {relative_path}\n"
                f"    reviewed {reviewed_digest}\n"
                f"    accepted {allowed or '(none recorded)'}\n"
                f"    actual   {actual}"
            )
        self.assertEqual(
            unexplained,
            [],
            "unexplained drift in reviewed seams — record it in "
            "accepted_drift_sha256 with a reason, or revert it:\n"
            + "\n".join(unexplained),
        )
        for relative_path, entry in accepted.items():
            with self.subTest(relative_path=relative_path):
                self.assertIn(relative_path, reviewed, "accepted drift for an unreviewed file")
                self.assertTrue(entry.get("reason", "").strip(), "accepted drift needs a reason")

    def test_application_migration_plan_is_ordered_and_named(self) -> None:
        migrations = self.manifest["application_migrations"]
        sequences = [migration["sequence"] for migration in migrations]
        self.assertEqual(sequences, sorted(sequences), "plan is out of order")
        self.assertEqual(len(set(sequences)), len(sequences), "a number is reused")
        # Cutover is last whatever number it ends up with — it is the only
        # irreversible migration and nothing may be planned after it.
        self.assertEqual(migrations[-1]["role"], "legacy_semantic_retirement")
        self.assertTrue(migrations[-1]["suggested_name"].endswith("_semantic_cutover.sql"))
        # Applied is a prefix of the plan, and the next to author follows it.
        applied = self.manifest["application_migrations_applied"]
        self.assertEqual(applied, sequences[: len(applied)])
        self.assertEqual(
            self.manifest["application_migrations_authored_next"], max(applied) + 1
        )
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
