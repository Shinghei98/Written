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
    for number, path in _migrations():
        if number < FIRST_BOUND_MIGRATION:
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
