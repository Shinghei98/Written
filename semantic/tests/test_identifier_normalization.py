"""A mixed identifier representation must never produce a successful empty run.

## The failure this is about

`aws/worker/resolve.py` builds a set of current observation ids from a psycopg
result — where a `uuid` column arrives as a `uuid.UUID` — and tested
`observation.id` against it, which `observation_from_row` has always stored as a
`str`. `str in {UUID, ...}` is `False` for every row.

So all 736 eligible observations were skipped as "not current", the job reported
success, wrote 9,841 other mappings, and produced none of the ones the route
existed to write. Nothing raised. Every query it depended on returned exactly the
right rows — 560 recordings found, 2,156 present observations found — and the
join between them was a type error.

**It is the only defect in that route that produced no signal at all.** The other
two named themselves in one line: a missing grant as `42501`, a rank of 0 as
`23514`.

## What is tested

Two things, and the second is the one that matters:

1. `identity()` collapses both representations to the same key, so a set built
   through it answers correctly whichever side is a `UUID`.
2. **The shape of the bug**, directly: a set of `UUID` objects tested against a
   `str` answers "absent" for a member that is present. That assertion is what
   makes this file a regression test rather than a demonstration — it fails if
   somebody ever decides the two are interchangeable and removes the
   normalization.

The arithmetic invariant in `resolve_user` is the runtime half of the same
guarantee: it fails a run whose ISRC dispositions do not sum, which is what this
bug would have tripped.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import sys
import uuid

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def resolve():
    """Load `aws/worker/resolve.py` by path, as the worker tests do.

    `aws/worker` is not a package — the Lambda extracts it flat — so it is loaded
    the same way `semantic/tests/test_semantic_contract.py` loads the compiler.
    """
    worker = pathlib.Path(REPOSITORY) / "aws" / "worker"
    path = worker / "resolve.py"
    if not path.exists():
        pytest.skip("resolve.py not present")

    # **The directory goes on `sys.path` first.** `resolve.py` imports `score`
    # and its other siblings by bare name, because the Lambda extracts that
    # directory flat into `/var/task`. Without this the import raises
    # `ModuleNotFoundError: score`.
    #
    # The first version of this fixture caught that and called `pytest.skip`,
    # which is the failure this whole file is about wearing different clothes:
    # four tests reported as skipped, the suite green, and the regression
    # unguarded. A test whose subject will not import has found something.
    # `tools/` too: `build.sh` stages `music_dictionary.py`, `music_works.py`
    # and `apple_catalog.py` flat beside the handler, so `resolve.py` imports
    # them by bare name as well. Reproducing the bundle's layout is what makes
    # importing it here the same act as importing it in the Lambda.
    for directory in (worker, pathlib.Path(REPOSITORY) / "tools"):
        if str(directory) not in sys.path:
            sys.path.insert(0, str(directory))
    spec = importlib.util.spec_from_file_location("written_worker_resolve", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_a_uuid_and_its_string_are_one_identity(resolve):
    value = uuid.uuid4()
    assert resolve.identity(value) == resolve.identity(str(value))
    assert resolve.identity(value) == str(value)
    assert isinstance(resolve.identity(value), str)


def test_a_set_built_through_identity_answers_for_either_representation(resolve):
    """The membership test the route actually performs."""
    present = uuid.uuid4()
    absent = uuid.uuid4()

    # Built from what psycopg returns: UUID objects.
    current = {resolve.identity(row) for row in (present, uuid.uuid4())}

    # Tested against what `observation_from_row` stores: a string.
    assert resolve.identity(str(present)) in current
    assert resolve.identity(str(absent)) not in current


def test_the_unnormalized_comparison_is_the_bug_and_stays_broken(resolve):
    """**The regression itself.** If this ever stops failing, the normalization
    has become unnecessary and this file should be deleted deliberately rather
    than quietly passing.

    A `str` is never a member of a set of `UUID` objects, whatever it spells. In
    the route that meant "not current" for every row, and 736 skips reported as a
    successful run.
    """
    value = uuid.uuid4()
    raw_set = {value}

    assert str(value) not in raw_set, (
        "a string is matching a set of UUID objects, which would mean the "
        "normalization in resolve.identity is no longer load-bearing"
    )
    assert value in raw_set
    # …and the normalized form recovers it, which is the whole fix.
    assert resolve.identity(str(value)) in {resolve.identity(v) for v in raw_set}


def test_every_isrc_disposition_bucket_is_named(resolve):
    """A skip must have a name, or no total can disagree with it.

    Read from the source rather than exercised, because the buckets are
    incremented inside a loop over a live database. What is checked is that the
    invariant enumerates every bucket the route can increment — a bucket the
    route writes and the sum does not read would reopen exactly the hole this
    closes, by making `isrc_unaccounted` wrong in the safe direction.
    """
    import re

    source = pathlib.Path(resolve.__file__).read_text()
    incremented = set(re.findall(r'counts\.get\("(isrc_[a-z_]+)", 0\) \+ 1', source))
    summed = set(re.findall(r'"(isrc_[a-z_]+)": counts\.get\("isrc_[a-z_]+", 0\),', source))

    assert incremented, "no isrc bucket is incremented; the scan broke"
    unsummed = incremented - summed - {"isrc_eligible"}
    assert not unsummed, (
        f"these buckets are counted and never summed, so a row landing in one "
        f"would be invisible to the arithmetic check: {sorted(unsummed)}"
    )
