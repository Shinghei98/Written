"""A decade only means something crossed with a language sphere.

The owner's reading, on their own library: *"eras strongly interact with
language sphere — 1970 UK music vs 1970 cantopop is very different"*. Measured,
`era:1970s` at 0.403 rested on ABBA, Stevie Wonder, Frankie Kao's 姑娘的酒渦 and
Fritz Kreisler — anglophone pop, Mandopop and a violin recital under one claim.

So the decade became an axis and `scene:<decade>_<sphere>` became the claim.
These fix the two rules that make that true and the one that nearly made it
false again.
"""

from __future__ import annotations

import os
import sys

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


@pytest.fixture(scope="module")
def works():
    tools = os.path.join(REPOSITORY, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    import music_works

    return music_works


def row(genres, released="1977-12-12", title="a", album=""):
    return {"title": title, "album": album, "genres": list(genres),
            "released": released}


def test_a_marked_genre_silences_the_unmarked_one_on_its_row(works):
    """The defect this rule exists for, with the row that produced it.

    Apple writes both the specific genre and the broad one: Frankie Kao's rows
    read `Mandopop|Music|Pop`. Read as equals, a Taiwanese singer yielded
    `sphere:anglophone` too, and his five 1970s rows became evidence for
    `scene:1970s_anglophone` — which then carried all thirteen of `era:1970s`'s
    mappings, so the composite spanned exactly the worlds it was built to
    separate.
    """
    kao = [row(["Mandopop", "Music", "Pop"], "1979-05-01", "姑娘的酒渦")]
    assert works.artist_spheres(kao) == {"sphere:mandarin"}

    abba = [row(["Pop", "Music", "Soft Rock", "Disco"])]
    assert works.artist_spheres(abba) == {"sphere:anglophone"}


def test_an_artist_can_still_span_two_spheres(works):
    """The union survives, which is why the rule is per row and not per artist.

    A Japanese act with an English-language album genuinely has two spheres. A
    rule that took the first marked genre and stopped would erase the second.
    """
    both = [row(["J-Pop"], "2015-01-01"), row(["Pop"], "2016-01-01")]
    assert works.artist_spheres(both) == {"sphere:anglophone", "sphere:japanese"}


def test_a_scene_needs_both_axes(works):
    """No sphere, no scene — and no decade, no scene.

    An artist with a decade and no stated sphere yields nothing rather than a
    scene in a sphere nobody established, which is `takes_decades`' refusal one
    axis over.
    """
    no_sphere = [row(["Classical"], "1975-01-01")]
    assert works.artist_scenes("x", no_sphere, {"era:1970s"}) == set()

    mandopop = [row(["Mandopop"], "1979-05-01")]
    assert works.artist_scenes("x", mandopop, {"era:1970s"}) == {"scene:1970s_mandarin"}


def test_a_scene_pairs_the_decade_and_the_sphere_on_one_row(works):
    """The defect that made `1990s English-language` mean nothing.

    Sheena Ringo has sixteen observations tagged `J-Pop` and two tagged `Rock` —
    2026 releases Apple filed without a language marker. The first version
    crossed the artist's eras with the artist's spheres, so a 1998 J-Pop single
    landed in `scene:1990s_anglophone`: a Japanese single reached through two
    rock tracks recorded twenty-eight years later.

    The shipped docstring predicted this in words and then chose the design that
    has it. Both halves are asserted here: what she must have, and what she must
    not.
    """
    ringo = [row(["J-Pop"], "1998-09-09", title=f"jp{i}") for i in range(3)]
    ringo.append(row(["Rock", "Music"], "2026-07-10", title="rock"))
    eras = works.artist_eras("Sheena Ringo", ringo)

    scenes = works.artist_scenes("Sheena Ringo", ringo, eras)
    assert scenes == {"scene:1990s_japanese", "scene:2020s_anglophone"}
    assert "scene:1990s_anglophone" not in scenes


def test_a_classical_period_is_never_crossed_with_a_sphere(works):
    """Baroque music is baroque in every language.

    `scene:baroque_anglophone` would describe nothing and would compete with
    `era:baroque` for the same evidence, so the cross-product is decades only —
    which is why the migration mints 30 concepts and not 65.
    """
    bach = [row(["Classical"], "2022-03-11",
                title="Matth\u00e4us-Passion, BWV 244",
                album="J.S. Bach: Matth\u00e4us-Passion, BWV 244")]
    assert works.artist_scenes("x", bach, {"era:baroque"}) == set()


def test_the_composer_supplies_a_period_apple_did_not_state(works):
    """Apple files the Bach passions as plain `Classical`.

    So `classical_eras` returned nothing, `takes_decades` was false, and a Bach
    row got no era at all — which is why `era:baroque` and its five siblings had
    existed as concepts since `0044` with zero assertions against them. The
    composer settles a fact about the work rather than about the listener.
    """
    bach = [row(["Classical"], "2022-03-11",
                title="Matthäus-Passion, BWV 244: Nr.52",
                album="J.S. Bach: Matthäus-Passion, BWV 244")]
    assert works.artist_eras("Raphaël Pichon & Pygmalion", bach) == {"era:baroque"}


def test_a_recording_date_never_becomes_a_decade_for_classical(works):
    """The guard that already existed, pinned because I claimed it did not.

    A 2022 recording of 1727 music must not read as 2020s music. `Classical` is
    absent from `DECADE_GENRES` and that is what stops it — asserted here so the
    composer work above cannot be "simplified" into a release-date fallback.
    """
    bach = [row(["Classical"], "2022-03-11",
                title="Johannes-Passion, BWV 245",
                album="J.S. Bach: St John Passion, BWV 245")]
    assert "era:2020s" not in works.artist_eras("English Baroque Soloists", bach)
