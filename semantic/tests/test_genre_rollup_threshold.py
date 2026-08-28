"""How many artists a genre needs is set in `score.py`, not in the resolver.

## What this is about

The genre rollup writes **one mapping per (genre, artist)** and applies no
threshold of its own — the scorer's saturation curve and eligibility bar decide
what survives. That is the right design: one rule, in one place.

It also means **the resolver's behaviour changes when constants it does not own
change**, silently and in the safe-looking direction. Raise `ELIGIBLE_STRENGTH`
or `HALF_WEIGHT` and the rollup quietly stops producing anything, with no test
failing and no run erroring, because "fewer assertions" is indistinguishable from
"this library had less in it".

The first version of the rollup got this wrong on paper twice in one sitting:

  * It read the bar as **0.25**, which is `ELIGIBLE_STRENGTH_BY_KIND['work']`. A
    genre concept's kind is `genre`, so its bar is `ELIGIBLE_STRENGTH` — 0.35.
  * It read `w` as **the artist count**. Each mapping contributes
    `evidence_weight * recency_weight * default_reliability * action_weight`,
    which averages about 0.6 per artist on the two live libraries.

Together those turned a real yield of four new crossings into a predicted twenty.
Nothing would have caught it: the code was correct, only the claim about it was
wrong, and a claim is what the next person reasons from.

## What is asserted

Not a number of artists — that is the mistake this file exists to prevent. What
is pinned is the **arithmetic relationship**, so that if either constant moves,
this fails and whoever moved it re-reads the rollup:

1. A genre concept is scored against `ELIGIBLE_STRENGTH`, not the `work` relief.
2. The weight needed to clear that bar, derived from the constants rather than
   quoted.
3. One artist is not enough — the property the "independence unit" design rests
   on, and the only thing here that is a genuine design commitment.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def score():
    """Load `aws/worker/score.py` the way the Lambda does — flat, by path."""
    worker = pathlib.Path(REPOSITORY) / "aws" / "worker"
    path = worker / "score.py"
    if not path.exists():
        pytest.fail(f"score.py is not at {path}; the worker layout moved")
    for directory in (worker, pathlib.Path(REPOSITORY) / "tools"):
        if str(directory) not in sys.path:
            sys.path.insert(0, str(directory))
    spec = importlib.util.spec_from_file_location("written_worker_score", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _saturate(weight: float, half: float) -> float:
    return weight / (weight + half)


def test_a_genre_is_scored_against_the_general_bar_not_the_work_relief(score):
    """**The error that produced a 5x overestimate.**

    `ELIGIBLE_STRENGTH_BY_KIND` is a per-kind *relief*, and `work` is the only
    kind that has one — a work is attested only by its own songs while a creator
    accumulates across everything they touch, so the same strength means more
    evidence. A genre is not a work and gets no relief.
    """
    by_kind = score.ELIGIBLE_STRENGTH_BY_KIND
    assert "genre" not in by_kind, (
        "a genre now has its own eligibility bar; the rollup's arithmetic in "
        "resolve.py and 0220 is written against ELIGIBLE_STRENGTH and must be "
        "re-derived"
    )
    # 0.25 was superseded by the owner, 2026-08-28: one weak direct evidence is
    # enough, for now. The relief sits just under the weakest single-track work
    # measured (0.042) and above the propagated λ-dust; the single-witness gate
    # in the derived tail is what now keeps one song from asserting its film.
    # The genre arithmetic below is unaffected — a genre still takes the plain
    # ELIGIBLE_STRENGTH bar, which is the claim this file exists to defend.
    assert by_kind.get("work") == 0.03
    bar = by_kind.get("genre", score.ELIGIBLE_STRENGTH)
    assert bar == score.ELIGIBLE_STRENGTH == 0.35


def test_the_weight_a_genre_needs_is_derived_from_the_constants(score):
    """Derived, never quoted — the whole point of the file.

    `w/(w+h) >= bar` rearranges to `w >= bar*h/(1-bar)`. If someone moves either
    constant this still computes the right answer, and the assertions below hold
    or fail on the real relationship rather than on a remembered number.
    """
    bar = score.ELIGIBLE_STRENGTH_BY_KIND.get("genre", score.ELIGIBLE_STRENGTH)
    half = score.HALF_WEIGHT
    needed = bar * half / (1.0 - bar)

    # Just below the derived weight must fail and just above must pass, which is
    # what proves `needed` is the boundary rather than merely near it.
    assert _saturate(needed * 0.999, half) < bar
    assert _saturate(needed * 1.001, half) >= bar

    # And it is a real requirement, not a formality satisfied by one mapping.
    assert needed > 1.0, (
        "one mapping now clears the genre bar, so a single artist would assert a "
        "genre and the (genre, artist) damping in resolve.py has stopped being "
        "the thing that makes the claim independent"
    )


def test_one_artist_is_never_enough(score):
    """The design commitment: forty tracks by one ensemble are one opinion.

    A mapping's weight is at most 1.0 — `evidence_weight` is 1.0 and the three
    factors multiplying it (`recency_weight`, `default_reliability`,
    `action_weight`) are each at most 1.0. So a single artist contributes at most
    1.0 however much of their catalogue somebody owns, and that must not clear
    the bar.
    """
    bar = score.ELIGIBLE_STRENGTH_BY_KIND.get("genre", score.ELIGIBLE_STRENGTH)
    most_one_artist_can_contribute = 1.0
    assert _saturate(most_one_artist_can_contribute, score.HALF_WEIGHT) < bar, (
        "a single artist can now assert a genre on their own, which defeats the "
        "reason the rollup keys its damping on the artist"
    )
