"""A refusal may say why, and may not quote what it refused.

`aws/worker/handler.py:_diagnostic` prints error type, sqlstate and constraint
name and never `str(error)` — with one deliberate exception. A `P0001`, which is
a `raise exception` written by one of our own migrations, has its message passed
through truncated, because that message is how an operator learns which clause
refused a batch. The comment beside it says what that costs:

    # **It is a convention rather than a mechanism, and that is the risk.**
    # A guard written later that interpolates a title would put it here.

Nothing checked it. This does: every `raise exception` in `supabase/migrations/`
is read, and any that interpolates a payload-bearing column is refused. Today all
sixteen that interpolate anything interpolate counts, a role name or a table
name, so this passes over the tree as it stands and exists for the seventeenth.

**Scope, stated so the guarantee is not overread.** This reads the format
arguments of `raise exception` statements. It cannot see a variable assigned a
title several lines earlier and then interpolated under a neutral name, and it
says nothing about `raise notice`, which does not travel through `_diagnostic`.
It closes the direct route, which is the one a guard written in a hurry takes.
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

#: Columns and fields that hold text a person or a provider wrote. A count of
#: them is fine and is what every current call site interpolates; the value is
#: not.
PAYLOAD_BEARING = (
    "normalized_payload",
    "encrypted_payload",
    "raw_payload",
    "mention_text",
    "canonical_title",
    "preferred_label",
    "mention_surface",
    "surface_text",
    "event_title",
    "organizer",
    "sample.name",
    "sample.label",
    "sample.title",
    ".summary",
    ".body",
)

#: `raise exception 'text %', arg, arg;` — everything after the format string is
#: what gets interpolated, and that is what is inspected.
RAISE = re.compile(
    r"raise\s+exception\s+(?P<message>'(?:[^']|'')*'(?:\s*'(?:[^']|'')*')*)"
    r"(?P<arguments>[^;]*);",
    re.IGNORECASE,
)


def migrations() -> list[pathlib.Path]:
    directory = pathlib.Path(REPOSITORY) / "supabase" / "migrations"
    files = sorted(directory.glob("*.sql"))
    assert len(files) > 150, f"only {len(files)} migrations found; the glob broke"
    return files


def test_no_migration_raises_a_payload_value():
    offenders: list[str] = []
    inspected = 0

    for path in migrations():
        source = path.read_text()
        for match in RAISE.finditer(source):
            arguments = match.group("arguments")
            if not arguments.strip().startswith(","):
                continue  # a constant message interpolates nothing
            inspected += 1
            lowered = arguments.lower()
            for token in PAYLOAD_BEARING:
                if token in lowered:
                    offenders.append(f"{path.name}: raise exception … {arguments.strip()}")
                    break

    # The scan must actually be finding statements, or a passing result means
    # only that the regex stopped matching.
    assert inspected >= 20, f"only {inspected} interpolating raises found; the scan broke"
    assert not offenders, (
        "these refusals interpolate a payload value, which `_diagnostic` "
        "forwards to CloudWatch for a P0001:\n  " + "\n  ".join(offenders)
    )


def test_the_scan_would_catch_one():
    """The predicate, answering the other way.

    A check that has only ever passed has not been shown to discriminate, and
    this one passes over the whole tree on its first run — which is exactly the
    shape that hides a broken regex.
    """
    planted = (
        "raise exception 'refused %', new.normalized_payload ->> 'title';"
    )
    match = RAISE.search(planted)
    assert match is not None
    assert "normalized_payload" in match.group("arguments").lower()
    assert any(token in match.group("arguments").lower() for token in PAYLOAD_BEARING)

    innocent = "raise exception '0198: % concept(s) name a prohibited subject', prohibited;"
    match = RAISE.search(innocent)
    assert match is not None
    assert not any(token in match.group("arguments").lower() for token in PAYLOAD_BEARING)
