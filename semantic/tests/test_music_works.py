"""The work a song was written for, against the strings Apple actually writes.

Every case here is a real album or title from one library. The rules look
obvious written down and are not: `Wicked: The Soundtrack` and
`Musical Jekyll & Hyde 2021 Korean Cast Recording Vol.1` name the same kind of
thing in two shapes, and `THE BOOK 3 - Single` names nothing at all while
looking identical to `oath sign - EP`.

**The abstentions are asserted as hard as the extractions.** A song that carries
`genre:anime` and names no series must gain no work — inventing a title to fill
the column is the failure this whole design is arranged to avoid, and it is the
one an over-eager rule produces silently.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the
repository-integration suite.
"""

import importlib.util
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
    path = os.path.join(tools, "music_works.py")
    if not os.path.exists(path):
        pytest.skip("music_works not present")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    spec = importlib.util.spec_from_file_location("written_music_works", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# --- mechanism 1: Apple says so --------------------------------------------

@pytest.mark.parametrize("title,album,expected", [
    ('Resister (From "Sword Art Online: Alicization") - Single', "",
     "Sword Art Online: Alicization"),
    ('Courage (From "Sword Art Online II") - Single', "", "Sword Art Online II"),
    ("", '(From "Musical Jekyll & Hyde") 2021 Korean Cast Recording, Vol. 2',
     "Musical Jekyll & Hyde"),
    ('Path of the Wind (From "My Neighbor Totoro")', "", "My Neighbor Totoro"),
])
def test_a_stated_work_is_read_off_either_field(works, title, album, expected):
    assert works.stated_work(title, album) == expected


def test_a_stated_work_beats_every_rule(works):
    """Confidence order. The album here would strip to something else entirely,
    and the quoted statement must win."""
    assert works.work_for(
        'Resister (From "Sword Art Online: Alicization") - Single',
        "Resister (Special Edition) - EP",
        ["Anime"],
    ) == "Sword Art Online: Alicization"


# --- mechanism 2: the album is the work ------------------------------------

@pytest.mark.parametrize("album,expected", [
    ("Wicked: The Soundtrack", "Wicked"),
    ("Persona 5: Dancing in Starlight (Soundtrack)", "Persona 5: Dancing in Starlight"),
    ("Footloose: The Musical (Original Broadway Cast Recording)", "Footloose: The Musical"),
    # The year and everything after it is an edition qualifier, not the work.
    ("Musical Jekyll & Hyde 2021 Korean Cast Recording Vol.1", "Musical Jekyll & Hyde"),
    ('Tv Series "Re: Zero -Starting Life in Another World-" 3rd Season (Original Soundtrack)',
     "Re: Zero -Starting Life in Another World-"),
])
def test_decoration_is_stripped_from_a_soundtrack_album(works, album, expected):
    assert works.work_from_album(album) == expected


def test_one_musical_is_one_concept_however_it_is_written(works):
    """The merge the plan asks for, and the reason the year is stripped.

    This library carries the same musical as a `From "…"` parenthetical on 38
    rows and as two differently-named cast recordings. If the album form kept
    `2021 Korean`, rule 6 would mint two concepts for one work — and nobody
    reading the ontology would see that they were the same thing."""
    stated = works.work_for(
        "", '(From "Musical Jekyll & Hyde") 2021 Korean Cast Recording, Vol. 2',
        ["Soundtrack"])
    from_album = works.work_for(
        "Musical Jekyll & Hyde 2021 Korean Cast Recording Vol.1", "", ["Soundtrack"])
    assert stated == from_album == "Musical Jekyll & Hyde"


@pytest.mark.parametrize("title,expected", [
    ("TVアニメ「オーバーロードIII」オープニングテーマ「VORACITY」 - EP", "オーバーロードIII"),
    ("TVアニメ『シュタインズ・ゲート』EDテーママキシシングル「刻司ル十二ノ盟約」 - EP",
     "シュタインズ・ゲート"),
    ("劇場版「進撃の巨人」前編~紅蓮の弓矢~エンディングテーマ YAMANAIAME", "進撃の巨人"),
    ("Netsuretsu! Anison Spirits the BEST - Cover Music Selection - "
     "TV Anime Series Overlord II - Single", "Overlord II"),
    ("TV Animation Higurashino Nakukoroni Gou Theme Song - Single",
     "Higurashino Nakukoroni Gou"),
])
def test_japanese_states_the_series_as_explicitly_as_english(works, title, expected):
    """`TVアニメ「X」` is the same statement as `From "X"`, and the **first**
    bracket is the series while a later one is the song — so Overlord III must
    win over VORACITY."""
    assert works.work_for(title, "", ["Anime"]) == expected


def test_an_album_row_carries_its_name_in_the_title(works):
    """`library_album` rows have the album name in `title` and no album at all,
    and half the soundtracks in a real library arrive that way. Without this they
    resolve to nothing while looking perfectly handled."""
    assert works.work_for("Wicked: The Soundtrack", "", ["Soundtrack"]) == "Wicked"


def test_an_album_that_is_only_decoration_yields_nothing(works):
    """`Original Soundtrack` with no name of its own must not become a work
    called the empty string, which would collect every such album into one."""
    assert works.work_from_album("Original Soundtrack") is None
    assert works.work_from_album("") is None


def test_a_compilation_is_not_a_work(works):
    """Several works, or none — but not one."""
    assert works.work_from_album("Anime Music Collection Piano Solo Vol.2") is None


# --- the gate ---------------------------------------------------------------

def test_an_ordinary_single_names_no_work(works):
    """**The rule that keeps this honest.** Without the media-genre gate,
    `THE BOOK 3 - Single` strips to `THE BOOK 3` and every ordinary release in
    the library would name a film that does not exist."""
    assert works.work_for("Idol", "THE BOOK 3 - Single", ["J-Pop"]) is None


def test_an_anime_single_with_no_named_series_abstains(works):
    """`Blood teller - EP` is anime music whose series is not in the data and
    not in the dictionary. It keeps its genre and gains no work.

    This is the case the whole design is arranged around: a plausible title is
    available — the song's own name — and taking it would be inventing.

    It used to use `Saihate`, which the library's owner then identified as a
    *Bleach: Thousand-Year Blood War* ending. That is the right way for an
    abstention to end: somebody names it, and the test moves to something still
    genuinely unknown rather than the dictionary staying empty to keep a test
    passing."""
    assert works.work_for("Blood teller", "Blood teller - EP", ["Anime"],
                          "Faylan") is None


def test_an_in_universe_band_settles_it_whatever_the_release(works):
    """A fictional band from an anime records nothing else, so this is a fact
    about the artist. `Ave Mujica` covers two releases here and will cover the
    next without an edit."""
    assert works.work_for("KiLLKiSS", "KiLLKiSS - Single", ["Anime"], "Ave Mujica") \
        == "BanG Dream! Ave Mujica"
    assert works.work_for("Alea jacta est", "Alea jacta est - EP", ["Anime"],
                          "Ave Mujica") == "BanG Dream! Ave Mujica"


def test_a_real_artist_is_not_bound_to_one_series(works):
    """LiSA sings for many series, so no artist rule fires and each release is
    named on its own. Binding her to one would be the Hopkins error with a band
    instead of a person."""
    assert works.artist_work("LiSA") is None
    assert works.work_for("Oath Sign", "oath sign - EP", ["Anime"], "LiSA") == "Fate/Zero"
    assert works.work_for("Gurenge", "Gurenge - EP", ["Anime"], "LiSA") \
        == "Demon Slayer: Kimetsu no Yaiba"


def test_a_series_carries_its_franchise(works):
    """Named once, both available: somebody with the Bleach: TYBW ending is
    evidence for Bleach as well, which is how the library's owner described it."""
    assert works.work_parents("Bleach: Thousand-Year Blood War") == ["Bleach"]
    assert works.work_parents("BanG Dream! Ave Mujica") == ["BanG Dream!"]
    assert works.work_parents("Wicked") == []


# --- mechanism 4: recognised by a person ------------------------------------

def test_a_hand_named_album_resolves(works):
    assert works.work_for("oath sign", "oath sign - EP", ["Anime"]) == "Fate/Zero"


def test_a_hand_named_album_beats_stripping(works):
    """`only my railgun - EP` would strip to `only my railgun`, the song's own
    name — which is exactly the wrong answer, and why mechanism 4 is consulted
    before mechanism 2."""
    assert works.work_for("only my railgun", "only my railgun - EP", ["Anime"]) \
        == "A Certain Scientific Railgun"


# --- mechanism 3: propagation -----------------------------------------------

def test_a_sibling_row_fills_in_the_work(works):
    """The free one. Both rows are the same song by the same artist; only one
    names the series."""
    rows = [
        {"title": 'Resister (From "Sword Art Online: Alicization") - Single',
         "album": "Resister - Single", "performer": "ASCA", "genres": ["Anime"]},
        {"title": "Resister", "album": "Resister (Special Edition) - EP",
         "performer": "ASCA", "genres": ["Anime"]},
    ]
    learned = works.propagate(rows)
    key = works.normalized_song_key("Resister", "ASCA")
    assert learned[key] == "Sword Art Online: Alicization"


def test_propagation_does_not_cross_artists(works):
    """A cover of the same song by somebody else is a different row, and the
    work is a fact about the recording rather than about the title."""
    a = works.normalized_song_key("Resister", "ASCA")
    b = works.normalized_song_key("Resister", "Someone Else")
    assert a != b


def test_the_song_key_ignores_decoration_but_not_the_title(works):
    """`Resister (From "…")` and `Resister` are one song; `Resister II` is not."""
    assert works.normalized_song_key('Resister (From "SAO")', "ASCA") \
        == works.normalized_song_key("Resister", "ASCA")
    assert works.normalized_song_key("Resister II", "ASCA") \
        != works.normalized_song_key("Resister", "ASCA")


def test_an_opera_is_a_work_too(works):
    """`From "Semiramide"` is in this library. The ontology's `work` kind covers
    an opera and an anime alike, which is why this is not a `media:` prefix."""
    assert works.stated_work('Bel raggio lusinghier (From "Semiramide")', "") \
        == "Semiramide"
