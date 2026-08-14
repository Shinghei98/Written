from __future__ import annotations

import unittest
from types import MappingProxyType

from written_ontology.source_policy import (
    DEFAULT_SOURCE_QUALITY,
    SOURCE_ACTION_PAIRS,
    SOURCE_ACTION_WEIGHTS,
    SOURCE_LAYOUT,
)


class SourcePolicyTests(unittest.TestCase):
    def test_catalog_is_closed_immutable_and_structurally_complete(self) -> None:
        self.assertIsInstance(DEFAULT_SOURCE_QUALITY, MappingProxyType)
        self.assertIsInstance(SOURCE_LAYOUT, MappingProxyType)
        self.assertIsInstance(SOURCE_ACTION_WEIGHTS, MappingProxyType)
        self.assertIsInstance(SOURCE_ACTION_PAIRS, MappingProxyType)
        self.assertEqual(
            set(DEFAULT_SOURCE_QUALITY),
            set(SOURCE_LAYOUT),
        )
        self.assertEqual(set(SOURCE_LAYOUT), set(SOURCE_ACTION_WEIGHTS))
        self.assertEqual(set(SOURCE_LAYOUT), set(SOURCE_ACTION_PAIRS))
        with self.assertRaises(TypeError):
            SOURCE_ACTION_WEIGHTS["youtube"]["liked"] = 0.0  # type: ignore[index]

        for source, weights in SOURCE_ACTION_WEIGHTS.items():
            with self.subTest(source=source):
                self.assertTrue(weights)
                self.assertTrue(all(0.0 < value <= 1.0 for value in weights.values()))
                expected = (
                    frozenset({("event", "scheduled")})
                    if source in {"apple_calendar", "google_calendar"}
                    else frozenset({("fitness_habit", "routine")})
                    if source == "healthkit"
                    else frozenset((action, action) for action in weights)
                )
                self.assertEqual(SOURCE_ACTION_PAIRS[source], expected)

    def test_high_risk_source_action_sets_are_exact(self) -> None:
        # `top_artist` and `top_track` were added here on 2026-08-14, six
        # migrations after `0139` gave them a weight in the database. Until then
        # the two answers disagreed and only this one was consulted by
        # `ObservationMapper`, so 560 correctly-weighted observations mapped to
        # nothing. **The exact set is the point**: it is what makes adding an
        # action to one side and not the other fail here rather than in a run
        # nobody reads.
        self.assertEqual(
            set(SOURCE_ACTION_WEIGHTS["spotify"]),
            {
                "followed_artist",
                "recently_played",
                "saved_album",
                "saved_track",
                "top_artist",
                "top_track",
            },
        )
        self.assertEqual(
            set(SOURCE_ACTION_WEIGHTS["music_library"]),
            {"library_song"},
        )
        self.assertEqual(
            set(SOURCE_ACTION_WEIGHTS["podcast"]),
            {"followed", "played", "saved"},
        )
        for source in ("apple_calendar", "google_calendar"):
            self.assertEqual(DEFAULT_SOURCE_QUALITY[source], 0.90)
            self.assertEqual(dict(SOURCE_ACTION_WEIGHTS[source]), {"scheduled": 0.90})
        self.assertEqual(SOURCE_LAYOUT["healthkit"], ("fitness", "fitness"))
        self.assertEqual(
            SOURCE_ACTION_PAIRS["healthkit"],
            frozenset({("fitness_habit", "routine")}),
        )
        self.assertNotIn(("activity_day", "activity_day"), SOURCE_ACTION_PAIRS["healthkit"])


if __name__ == "__main__":
    unittest.main()
