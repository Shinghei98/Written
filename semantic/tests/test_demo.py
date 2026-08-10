from __future__ import annotations

import json
import unittest

from written_ontology.demo import run_demo


class DemoTests(unittest.TestCase):
    def test_demo_converges_without_identity_inference(self) -> None:
        result = run_demo()
        assertions = result["cross_source_assertions"]
        self.assertEqual(len(assertions), 1)
        self.assertEqual(assertions[0]["concept_key"], "affinity:culture:italy")
        self.assertEqual(assertions[0]["state"], "pending_user_review")
        # Calendar is deliberately routed through typed booking/travel
        # candidates, so the generic convergence demo sees music + video only.
        self.assertEqual(assertions[0]["breadth"], 2)
        self.assertFalse(result["identity_firewall"]["italian_ancestry_inferable"])
        self.assertEqual(result["music_only_cross_source_assertions"], 0)
        self.assertTrue(result["one_tap_removal"]["suppression_survives_recompute"])

    def test_demo_is_deterministic(self) -> None:
        first = json.dumps(run_demo(), sort_keys=True)
        second = json.dumps(run_demo(), sort_keys=True)
        self.assertEqual(first, second)

    def test_repeated_music_is_one_lineage_and_one_group(self) -> None:
        repeated = run_demo()["repeated_music"]
        self.assertEqual(repeated["unique_lineages"], 1)
        self.assertEqual(repeated["breadth"], 1)
        self.assertLess(repeated["strength"], 0.60)


if __name__ == "__main__":
    unittest.main()
