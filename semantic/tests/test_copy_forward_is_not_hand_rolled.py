"""A version copy-forward must go through `ontology.copy_forward_version`.

## Why this exists

Publishing a new ontology version means carrying five tables forward:
`concept_revisions`, `concept_labels`, `concept_edges`, `motif_rules` and
`external_concept_links`. Every migration that published a version wrote those
five inserts out by hand.

**`0213` exists because one of them wrote four.** The mint dropped
`external_concept_links` and took 760 links down to 1, in production, silently —
nothing failed, because a missing link is not an error, it is an absence.

`0221` added a second thing that must not be forgotten: identity-registry
concepts (`recording:isrc_*`) are **not** carried forward, because identity is
not vocabulary. That one is worse than the first, because forgetting it does not
lose rows — it silently *restores* 560 concepts to the ontology, and a restored
concept looks exactly like a concept that was supposed to be there.

So the copy-forward now lives in one function with both rules inside it, and
this test is what stops the next author writing the sixth hand-rolled copy that
has neither.

## What is asserted

That no migration numbered above `0221` performs a copy-forward by hand — that
is, inserts into one of the five versioned tables while selecting from the same
table. That is the shape of a copy-forward and nothing else has it: a migration
inserting *new* vocabulary selects from `external_entities`, a CTE, or values.

The check is deliberately about the **shape**, not about a function name being
mentioned, because a migration that calls the helper *and* hand-rolls an extra
table would pass a name check and fail this one.
"""

from __future__ import annotations

import os
import pathlib
import re

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)

# The five tables a version carries forward.
VERSIONED_TABLES = (
    "concept_revisions",
    "concept_labels",
    "concept_edges",
    "motif_rules",
    "external_concept_links",
)

# `0221` is the migration that introduced the helper; it and everything before it
# are history and are not rewritten. A migration is only bound by a rule that
# existed when it was written.
FIRST_BOUND_MIGRATION = 222

# **Grandfathered offenders — deployed history, not licence.** These migrations
# were bound by the rule and broke it: five (0346, 0349, 0355, 0356, 0389)
# hand-rolled the whole five-table copy-forward without the helper, and the
# rest hand-inserted into a versioned table beside a helper call. They shipped
# while this suite was red and they have run against production, so rewriting
# the files would make replay disagree with what actually ran. **Measured
# 2026-08-28 against production before grandfathering:** current version 0.9.0
# holds zero identity-registry revisions and zero identity-registry labels —
# the hand-rolls copied from predecessor versions that were already clean, so
# neither of the two defects the helper guards against (the 0213 dropped table,
# the 0221 identity restore) occurred. A filename added to this set needs the
# same measurement, and a migration not yet deployed never qualifies: fix it
# instead.
GRANDFATHERED = frozenset({
    "0346_the_recognised_headings_arrive.sql",
    "0349_the_audit_slices_arrive.sql",
    "0350_two_names_for_one_genre_become_one.sql",
    "0355_the_regional_tier_arrives.sql",
    "0356_the_cultures_arrive.sql",
    "0357_the_kept_japan_folds_into_its_culture.sql",
    "0366_the_provenance_twins_fold.sql",
    "0370_two_keeps_of_one_identity_fold.sql",
    "0389_the_deep_screen_genre_layer.sql",
    "0396_a_published_version_asks_for_its_recompute.sql",
    "0402_classical_music_was_already_classical.sql",
    "0404_two_translations_of_one_novel_were_two_concepts.sql",
    "0438_a_field_shows_its_name.sql",
    "0439_a_language_has_a_name.sql",
    "0449_a_promotion_into_a_grave_revives_or_refuses.sql",
    "0451_a_rejected_parent_is_a_decision.sql",
    "0452_a_repair_that_changes_nothing_publishes_nothing.sql",
    "0462_the_song_nominates_its_film.sql",
})


def _migrations():
    directory = pathlib.Path(REPOSITORY) / "supabase" / "migrations"
    if not directory.is_dir():
        pytest.fail(f"no migrations directory at {directory}")
    for path in sorted(directory.glob("*.sql")):
        match = re.match(r"^(\d+)_", path.name)
        if match:
            yield int(match.group(1)), path


def test_the_helper_exists_and_names_both_rules():
    """The thing the rest of this file defends must actually be there."""
    source = None
    for _, path in _migrations():
        text = path.read_text()
        if "create or replace function ontology.copy_forward_version" in text:
            source = text
            break
    assert source, "ontology.copy_forward_version is not defined in any migration"

    for table in VERSIONED_TABLES:
        assert f"ontology.{table}" in source, (
            f"copy_forward_version does not mention ontology.{table}; a "
            f"copy-forward that carries four of five tables is the 0213 defect"
        )
    assert "is_identity_registry_concept" in source, (
        "copy_forward_version no longer applies the identity-registry exclusion, "
        "so recordings would be restored to the next published ontology version"
    )


def test_no_later_migration_hand_rolls_a_copy_forward():
    """**The regression.** A sixth hand-written copy-forward fails here."""
    offenders = []
    names = {path.name for _, path in _migrations()}
    missing = GRANDFATHERED - names
    assert not missing, (
        "grandfathered migrations that no longer exist — prune them from the "
        "set rather than letting it hold names nothing checks: "
        + ", ".join(sorted(missing))
    )
    for number, path in _migrations():
        if number < FIRST_BOUND_MIGRATION:
            continue
        if path.name in GRANDFATHERED:
            continue
        text = path.read_text()
        # Strip comments so a migration *describing* the pattern is not an
        # offender — this file's own subject matter gets written about a lot.
        body = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("--")
        )
        for table in VERSIONED_TABLES:
            inserts = re.search(
                rf"insert\s+into\s+ontology\.{table}\b(.*?);",
                body,
                re.IGNORECASE | re.DOTALL,
            )
            if inserts and re.search(
                rf"from\s+ontology\.{table}\b", inserts.group(1), re.IGNORECASE
            ):
                offenders.append(f"{path.name}: ontology.{table}")

    assert not offenders, (
        "these migrations copy a versioned table into a new version by hand "
        "instead of calling ontology.copy_forward_version, so they carry "
        "whichever rules their author remembered: " + ", ".join(offenders)
    )
