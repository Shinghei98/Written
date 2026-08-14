"""The games lane's two vocabularies, checked against each other.

`GAME_TAG_CATALOGUE` in `aws/worker/resolve.py` maps a channel keyword to a
concept *key*, and `semantic/ontology/games_*.csv` mints the concepts those keys
name. Two files holding one vocabulary is the arrangement `0149` already carries
for `work_titles.mjs`, and its docstring names the failure it cannot check for
itself: *"Every `key` must already exist in `ontology.concepts`. A key that does
not is not an error here — the resolver drops it silently, which is exactly the
failure mode that is hard to see later."*

So it is checked here. A game added to the catalogue and forgotten in the CSVs
resolves to nothing, on every account, with no error at either end — the same
silence that hid the `keywords`/`tags` mismatch for as long as it existed.

**And the rule that governs what may be added**, borrowed from
`work_titles.mjs` because the hazard is identical: *an alias must not be a
word*. `wow` is an exclamation before it is Warcraft. That one cannot be checked
by a computer — a word list would be a third vocabulary — so what is checked is
the shape it takes when the rule is followed: the abbreviations live in the
catalogue and never in the ontology's alias table, where some other lane's free
text could reach them.

A text reader rather than an import: `resolve.py` pulls in psycopg and the
worker's own modules, and this needs neither.
"""

import ast
import csv
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_configured = os.environ.get("WRITTEN_REPOSITORY_PATH")
REPO = Path(_configured).resolve() if _configured else None


def _catalogue(repo: Path) -> dict[str, str]:
    text = (repo / "aws" / "worker" / "resolve.py").read_text(encoding="utf-8")
    match = re.search(r"GAME_TAG_CATALOGUE = (\{.*?\n\})", text, re.S)
    if match is None:
        raise AssertionError("GAME_TAG_CATALOGUE not found in resolve.py")
    return ast.literal_eval(match.group(1))


def _csv_rows(repo: Path, name: str) -> list[dict[str, str]]:
    path = repo / "semantic" / "ontology" / f"games_{name}.csv"
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


@unittest.skipIf(REPO is None, "WRITTEN_REPOSITORY_PATH is not configured")
class GameTagCatalogueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalogue = _catalogue(REPO)
        cls.concepts = _csv_rows(REPO, "concepts")
        cls.aliases = _csv_rows(REPO, "aliases")

    def test_every_catalogue_key_is_a_minted_work(self) -> None:
        """The check `work_titles.mjs` says it cannot make for itself."""
        minted = {
            row["concept_key"]: row["concept_kind"] for row in self.concepts
        }
        for tag, key in sorted(self.catalogue.items()):
            with self.subTest(tag=tag):
                self.assertIn(key, minted, f"{tag!r} names an unminted concept")
                # `work` is what `list_assertions` shows and what the lane's
                # type hint admits. A game filed as a `topic` would resolve,
                # score, and never appear — the failure the games work exists
                # to end, wearing a different name.
                self.assertEqual(minted[key], "work")

    def test_every_work_carries_its_own_key_as_a_label(self) -> None:
        """`0149`'s arrangement, and the whole reason a key resolves.

        The lane emits `work:hearthstone`, not `Hearthstone`; the ordinary
        exact-alias path matches it only because the key is also an `alternate`
        label. Without the row the term resolves to nothing, silently.
        """
        labelled = {
            row["concept_key"]
            for row in self.aliases
            if row["alias"] == row["concept_key"] and row["alias_type"] == "alternate"
        }
        self.assertEqual(labelled, set(self.catalogue.values()))

    def test_abbreviations_are_not_ontology_aliases(self) -> None:
        """**The shape the word rule takes when it is followed.**

        `ffxiv` and `warcraft` belong to this lane and to nothing else. An
        abbreviation in the ontology's alias table is reachable by every lane
        that resolves free text, which is how `bleach` — an ordinary word, and
        a real alias of a real work — became the thing that narrowed this lane
        in the first place.
        """
        spellings = {row["alias"].casefold() for row in self.aliases}
        for tag in self.catalogue:
            if tag in {row["preferred_label"].casefold() for row in self.concepts}:
                continue  # the full name, which is the label
            with self.subTest(tag=tag):
                self.assertNotIn(tag, spellings)

    def test_wow_is_not_in_the_catalogue(self) -> None:
        """The named instance of the rule, pinned so it cannot come back as a
        convenience. Losing a true term is the cheaper mistake."""
        self.assertNotIn("wow", self.catalogue)


if __name__ == "__main__":
    unittest.main()
