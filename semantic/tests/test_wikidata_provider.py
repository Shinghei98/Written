from __future__ import annotations

import unittest

from written_ontology.providers.wikidata import WikidataProvider


def claim(target: str, *, rank: str = "normal", snaktype: str = "value") -> dict[str, object]:
    return {
        "rank": rank,
        "mainsnak": {
            "snaktype": snaktype,
            "datavalue": {"value": {"id": target}},
        },
    }


class WikidataProviderTests(unittest.TestCase):
    def test_claims_keep_exact_predicates_and_skip_unsafe_snaks(self) -> None:
        entity = {
            "claims": {
                "P495": [claim("Q38")],
                "P17": [claim("Q999", rank="deprecated")],
                "P364": [claim("Q652", snaktype="novalue")],
                "P136": [claim("not-a-qid")],
            }
        }
        self.assertEqual(
            WikidataProvider._safe_claims(entity),
            (
                {
                    "property_id": "P495",
                    "predicate": "country_of_origin",
                    "target_external_id": "Q38",
                    "rank": "normal",
                    "status": "candidate_only",
                },
            ),
        )

    def test_cache_projection_is_minimized(self) -> None:
        provider = WikidataProvider(
            "WrittenOntologyTest/0.1 (maintainer@invalid.test)",
            minimum_request_interval_seconds=0,
        )
        entity = {
            "id": "Q1",
            "lastrevid": 123,
            "descriptions": {"en": [{"value": "must not be cached"}]},
            "aliases": {"en": [{"value": f"alias-{index}"} for index in range(30)]},
            "claims": {"P31": [claim("Q5")], "P999": [claim("Q2")]},
        }
        projection = provider._cache_projection(entity)
        self.assertNotIn("descriptions", projection)
        self.assertNotIn("P999", projection["claims"])
        self.assertEqual(len(projection["aliases"]["en"]), 20)
        self.assertEqual(provider._entity_kind(projection), "creator")

    def test_placeholder_user_agent_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            WikidataProvider("WrittenOntology/0.1 (contact@example.com)")


if __name__ == "__main__":
    unittest.main()
