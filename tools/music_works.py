#!/usr/bin/env python3
"""Finding the work a song was written for.

Four mechanisms over what Apple already states, in descending confidence — see
`music_dictionary` for the tables. This module is only the reading of them, and
it is deliberately separate so the rules can be tested without a database.

**The abstention is the important behaviour.** A row whose genre says
`Anime` and whose album names no series keeps `genre:anime` and gains no work.
Every other outcome here — a stated `From "…"`, a stripped soundtrack album, a
propagated sibling, a hand-named album — is something Apple said or somebody
recognised. Nothing is guessed from a title.
"""

from __future__ import annotations

import re
import unicodedata

from music_dictionary import (
    ARTIST_ERA,
    CATALOGUE_COMPOSERS,
    CATALOGUE_PREFIXES,
    CLASSICAL_COMPOSERS,
    JUNK_EXACT,
    MAX_COMPOSERS,
    NAME_ALIASES,
    NAME_SUFFIXES,
    JUNK_SUBSTRINGS,
    COMPILATION_MARKERS,
    NEVER_SPLIT,
    SPLIT_SEPARATORS,
    TRANSLITERATED,
    ARTIST_WORK,
    CLASSICAL_ERAS,
    COMPILATION_MIN_ALBUM,
    COMPILATION_MIN_ROWS,
    DECADE_GENRES,
    GENRE_TRANSLATIONS,
    decade_of,
    MEDIA_GENRES,
    WORK_BY_ALBUM,
    WORK_DECORATIONS,
    WORK_EN_SERIES_PATTERN,
    WORK_FROM_PATTERN,
    WORK_JP_PATTERN,
    WORK_NOT_A_WORK,
    WORK_ALIASES,
    WORK_PARENT,
    WORK_SERIES_PATTERN,
    WORK_TRAILING_PATTERN,
)

_FROM = re.compile(WORK_FROM_PATTERN)
_JP = re.compile(WORK_JP_PATTERN)
_EN_SERIES = re.compile(WORK_EN_SERIES_PATTERN, re.IGNORECASE)
_SERIES = re.compile(WORK_SERIES_PATTERN)
_TRAILING = re.compile(WORK_TRAILING_PATTERN, re.IGNORECASE)


def stated_work(title: str, album: str) -> str | None:
    """Mechanism 1 — `From "X"`, on either field.

    Apple naming the work outright. Checked before everything else because it is
    the only one that needs no rule about how albums are named: the quotes are
    the statement.
    """
    for text in (title or "", album or ""):
        for pattern in (_FROM, _JP, _EN_SERIES):
            match = pattern.search(text)
            if match:
                found = match.group(1)
                # A release suffix can ride along when the pattern's tail
                # alternative is end-of-string: `TV Anime Series Overlord II -
                # Single` captured `Overlord II - Single`.
                found = re.sub(r"\s-\s(Single|EP)$", "", found, flags=re.IGNORECASE)
                found = found.strip(" 　-–—:")
                if found:
                    return canonical_work(found)
    return None


def work_from_album(album: str) -> str | None:
    """Mechanism 2 — the album is the work, wearing decoration.

    `Wicked: The Soundtrack` → `Wicked`. Decorations are stripped longest-first
    so `: The Soundtrack` is not left as `: The` by a shorter rule matching
    first, and a trailing `Vol. 2` or `Part.3` goes after them.

    Returns `None` for an album that strips to nothing, which is how
    `Original Soundtrack` with no title of its own declines to become a work
    called the empty string.
    """
    if not album:
        return None
    if album in WORK_NOT_A_WORK:
        return None
    lowered = album.casefold()
    if any(marker in lowered for marker in COMPILATION_MARKERS):
        return None

    # **A single or an EP is never a work.** It is a release of a song, and
    # stripping its decoration yields the song's own name — so `Saihate - Single`
    # would become a series called *Saihate* and `Resister (Special Edition) -
    # EP` a series called *Resister (Special Edition*. That is the invention this
    # whole module is arranged to avoid, and it was live until three tests caught
    # it at once. An anime single whose series is genuinely named goes through
    # mechanism 1 or 4, both of which run before this.
    if re.search(r"\s-\s(Single|EP)$", album, re.IGNORECASE):
        return None

    series = _SERIES.search(album)
    if series:
        # No `strip("-")`: the quotes already delimit it, and `Re: Zero
        # -Starting Life in Another World-` ends in one that belongs to the name.
        # Canonicalised like every other branch — that long form and `Re:Zero`
        # are one anime, and this early return was the one path that forgot.
        return canonical_work(series.group(1).strip())

    cleaned = album
    for decoration in WORK_DECORATIONS:
        cleaned = cleaned.replace(decoration, " ")
    cleaned = _TRAILING.sub("", cleaned)
    # **A year marks an edition, not the work.** `Musical Jekyll & Hyde 2021
    # Korean Cast Recording` is a 2021 Korean production *of* Jekyll & Hyde, and
    # keeping the qualifier would leave it unable to merge with the
    # `From "Musical Jekyll & Hyde"` form that the same library also carries —
    # two concepts for one musical, which is precisely what rule 6 exists to
    # prevent. Everything from a standalone year onward goes.
    cleaned = re.sub(r"\s(?:19|20)\d{2}\b.*$", "", cleaned)
    # Left-over separators from the middle of a stripped name.
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    # **Only strip a bracket that has lost its partner.** Blindly stripping `()`
    # from the ends truncated `A Symphonic Celebration (Music from the Studio
    # Ghibli Films of Hayao Miyazaki)` to an unbalanced string — a work whose
    # name was visibly cut off.
    cleaned = cleaned.strip(" -:,")
    if cleaned.count("(") != cleaned.count(")"):
        cleaned = cleaned.strip("()").strip(" -:,")
    return canonical_work(cleaned) if cleaned else None


def canonical_work(work: str) -> str:
    """One work, one name — whatever language or depth the string used.

    The same rule as for people: `Re:ゼロから始める異世界生活` and `Re:Zero` are one
    anime, and this library carries both. Applied to every mechanism's output, so
    the merge happens once rather than at each call site.
    """
    return WORK_ALIASES.get((work or "").strip(), (work or "").strip())


def named_work(album: str) -> str | None:
    """Mechanism 4 — an album somebody recognised and wrote down."""
    named = WORK_BY_ALBUM.get(album)
    return canonical_work(named) if named else None


def artist_work(performer: str) -> str | None:
    """Mechanism 5 — an artist who exists only inside one work.

    A fictional band from an anime records nothing else, so this is a fact about
    the artist rather than about any release: `Ave Mujica` covers two albums here
    and will cover the next without an edit. Stronger and shorter than listing
    releases.

    Real artists who merely sing many anime themes are absent by design — LiSA,
    ASCA, fripSide, ReoNa and OxT work across series, and filing them under one
    would be the Hopkins error with a band instead of a person.
    """
    named = ARTIST_WORK.get((performer or "").strip())
    return canonical_work(named) if named else None


def work_parents(work: str) -> list[str]:
    """The franchise chain above a work, nearest first.

    *Bleach: Thousand-Year Blood War* is a series within *Bleach*, and somebody
    who has one is evidence for both — so only the specific one has to be named
    and the rest follows. Cycle-guarded, because a table edited by hand can
    always name its own ancestor.
    """
    chain: list[str] = []
    seen = {work}
    parent = WORK_PARENT.get(work)
    while parent and parent not in seen:
        chain.append(parent)
        seen.add(parent)
        parent = WORK_PARENT.get(parent)
    return chain


def is_media_row(genres: list[str]) -> bool:
    """Whether Apple says this row is music for something."""
    return any(genre in MEDIA_GENRES for genre in genres or ())


def work_for(title: str, album: str, genres: list[str],
             performer: str = "") -> str | None:
    """The work this row belongs to, or `None`.

    **Order is confidence.** A stated `From "…"` beats a hand-named album, which
    beats stripping the album — because the first two are somebody's statement
    and the third is a rule about naming conventions.

    The album is only read as a work when Apple's genre says the row is media
    music. Without that gate `THE BOOK 3 - Single` would become a work, and
    every ordinary single in the library would name a film that does not exist.
    """
    stated = stated_work(title, album)
    if stated:
        return stated

    # An in-universe band settles it whatever the release is called.
    by_artist = artist_work(performer)
    if by_artist:
        return by_artist

    # **An album row carries its name in `title` and has no album of its own.**
    # `library_album` rows are exactly that shape, and half the soundtracks in a
    # real library arrive as one: `Wicked: The Soundtrack` with a null album.
    # Without this they resolve to nothing while looking perfectly handled.
    as_album = album or title

    named = named_work(as_album)
    if named:
        return named

    if is_media_row(genres):
        return work_from_album(as_album)
    return None


def normalized_song_key(title: str, performer: str) -> str:
    """The key mechanism 3 propagates along: one song by one artist.

    Casefolded and accent-folded so `Resister` on two differently-decorated
    albums is one song. Deliberately *not* `normalize_text` from the package —
    that strips punctuation to spaces, which would merge songs whose titles
    differ only by it.
    """
    def fold(value: str) -> str:
        decomposed = unicodedata.normalize("NFKD", (value or "").casefold().strip())
        return "".join(c for c in decomposed if not unicodedata.combining(c))

    # A decoration on the title should not stop two rows being the same song.
    # Both halves matter: `Resister (From "…") - Single` and `Resister` are one
    # song, and dropping only the parenthetical leaves the ` - Single` behind —
    # which is a different key, and the propagation silently finds nothing.
    cleaned = re.sub(r"\s*\((?:From|Feat\.?|feat\.?)[^)]*\)", "", title or "")
    cleaned = re.sub(r"\s-\s(Single|EP)$", "", cleaned, flags=re.IGNORECASE)
    return f"{fold(cleaned)}\x1f{fold(performer)}"


def propagate(rows: list[dict]) -> dict[str, str]:
    """Mechanism 3 — `song key -> work`, learned from the rows that name one.

    Free, and it already pays: `Resister (Special Edition) - EP` names no work
    while `Resister (From "Sword Art Online: Alicization") - Single` is the same
    song by the same artist in the same library.

    **First writer wins, and the input is expected in confidence order.** A song
    that somehow named two works keeps the first; recording both would let one
    ambiguous row spread its ambiguity across every copy.
    """
    learned: dict[str, str] = {}
    for row in rows:
        work = work_for(row.get("title", ""), row.get("album", ""),
                        row.get("genres", []), row.get("performer", ""))
        if not work:
            continue
        key = normalized_song_key(row.get("title", ""), row.get("performer", ""))
        learned.setdefault(key, work)
    return learned


# ---------------------------------------------------------------------------
# Era
#
# **Two vocabularies, because the sources are genuinely different.** A classical
# period is *stated by Apple as a genre* — `Baroque Era`, `Romantic Era` — so it
# is read. Popular music has no such field, so its era comes from release dates,
# which is where the care is needed: a release date is the date of *that
# recording*, not of the song.

def english_genre(genre: str) -> str:
    """Apple's genre in English, whatever locale it arrived in.

    Load-bearing for era as well as for genre: without it a Chinese-labelled
    `巴洛克音樂` row would not match `Baroque Era` and a classical library would
    silently have no periods at all.
    """
    text = (genre or "").strip()
    return GENRE_TRANSLATIONS.get(text, text)


def classical_eras(genres: list[str]) -> set[str]:
    """Periods Apple stated. No dates, no inference."""
    return {
        CLASSICAL_ERAS[english_genre(genre)]
        for genre in genres or ()
        if english_genre(genre) in CLASSICAL_ERAS
    }


def takes_decades(genres: list[str]) -> bool:
    """Whether a decade means anything for this music.

    A decade is a claim about popular-music style. It says nothing about a Bach
    partita, and a recording date would actively mislead — so anything outside
    this family gets no era rather than a wrong one.
    """
    return any(english_genre(genre) in DECADE_GENRES for genre in genres or ())


def dates_are_trustworthy(rows: list[dict]) -> bool:
    """Whether this artist's release dates describe songs or one release event.

    Both conditions are required and each alone is common: a classical soloist
    legitimately has 65 rows sharing one date, and an ordinary album legitimately
    has one date. Together they select a compilation — and on the real library,
    exactly one artist.
    """
    years = {(row.get("released") or "")[:4] for row in rows}
    years.discard("")
    if len(years) != 1 or len(rows) < COMPILATION_MIN_ROWS:
        return True

    per_album: dict[str, int] = {}
    for row in rows:
        album = row.get("album") or row.get("title") or ""
        per_album[album] = per_album.get(album, 0) + 1
    return max(per_album.values(), default=0) < COMPILATION_MIN_ALBUM


def artist_eras(performer: str, rows: list[dict]) -> set[str]:
    """Every era this artist's rows support.

    Order matters. A hand-named artist wins outright, because the reason for
    naming one is that the dates are known to be wrong. Classical periods come
    next and need no dates at all. Decades come last and only for the genres
    where a decade is a statement about style.
    """
    named = ARTIST_ERA.get((performer or "").strip())
    if named:
        return set(named)

    eras: set[str] = set()
    for row in rows:
        eras |= classical_eras(row.get("genres", []))
    if eras:
        return eras

    if not any(takes_decades(row.get("genres", [])) for row in rows):
        return set()
    if not dates_are_trustworthy(rows):
        # Known-unreliable dates and nobody has named the artist. An era is
        # withheld rather than asserted from a compilation's release date.
        return set()

    for row in rows:
        year = (row.get("released") or "")[:4]
        if year.isdigit():
            decade = decade_of(int(year))
            if decade:
                eras.add(decade)
    return eras


# ---------------------------------------------------------------------------
# Names — rules 1, 2 and 4 applied together
#
# The order is the whole of it: split first, then judge each part. Judging the
# whole string would file `Berlin Philharmonic & Claudio Abbado` under neither
# name, and splitting after transliteration would need every compound spelled out
# in the table.


def is_junk(name: str) -> bool:
    """Apple's editorial accounts, personal playlists and "Various Artists".

    A substring test, because the shape is `<somebody>的 Apple Music` as well as
    `Apple Music 古典樂` — a personal playlist credited as though it were an
    artist.
    """
    text = (name or "").strip()
    if not text:
        return True
    if text in JUNK_EXACT:
        return True
    return any(fragment in text for fragment in JUNK_SUBSTRINGS)


def split_credits(credit: str) -> list[str]:
    """One credit string into the people in it.

    **Never on `・` or `·`.** Those join the parts of one transliterated name —
    `尼科洛・帕格尼尼` is Paganini — and 98 names in this library contain one, so
    splitting there invents people who do not exist. The separators that do split
    are `&`, `,` and `、`, the last of which was missing until a Japanese
    voice-actor credit stayed welded into a single "artist".
    """
    parts = [credit or ""]
    for separator in SPLIT_SEPARATORS:
        parts = [piece for part in parts for piece in part.split(separator)]

    # **Rejoin what was never a separate person.** `Dwayne Abernathy, Jr.` splits
    # into two, and `Jr.` became a concept in its own right; bare numbers arrive
    # the same way. A fragment like this belongs to the name before it.
    joined: list[str] = []
    for part in (p.strip() for p in parts):
        if not part:
            continue
        if joined and (part.casefold() in NAME_SUFFIXES or part.isdigit()):
            joined[-1] = f"{joined[-1]}, {part}"
            continue
        joined.append(part)
    return joined


def resolve_name(name: str) -> str | None:
    """One person, in their own language, or `None` for junk.

    `尚・西貝流士` becomes `Jean Sibelius` because Chinese is not that name's
    language; `久石讓` stays, because it is. Anything not recognised stays as
    written — an unmerged duplicate is the acceptable failure, and a confidently
    wrong name is not.
    """
    text = (name or "").strip()
    if is_junk(text):
        return None
    # Spelling variants first, then language. A variant may itself be the
    # Chinese form of a Western name.
    text = NAME_ALIASES.get(text, text)
    return TRANSLITERATED.get(text, text)


def people_in(credit: str, limit: int | None = None) -> list[str]:
    """Every person a credit names, split, de-junked and in their own language.

    `limit` caps how many are kept — used for composers, where a pop track's
    credit list runs to seventeen names and only the first few are who the song
    is *by*. Applied after junk is dropped, so a placeholder does not consume one
    of the places.
    """
    seen: list[str] = []
    for part in split_credits(credit):
        person = resolve_name(part)
        if person and person not in seen:
            seen.append(person)
            if limit is not None and len(seen) >= limit:
                break
    return seen


def composers_in(credit: str) -> list[str]:
    """The writers a song is by, capped at `MAX_COMPOSERS`."""
    return people_in(credit, limit=MAX_COMPOSERS)


# ---------------------------------------------------------------------------
# Classical: recovering the composer and the piece
# ---------------------------------------------------------------------------

# Longest prefix first, so `BuxWV` is not read as `BWV` and `Hob.` is not read
# as a bare `H`. Escaped because `.` is in several of them.
_CATALOGUE_RE = re.compile(
    r"\b(" + "|".join(re.escape(p) for p in sorted(
        CATALOGUE_PREFIXES, key=len, reverse=True)) + r")\s*(\d+[a-zA-Z]?)"
)

# `Composer: Work` — the classical labelling convention, and the highest-
# confidence form because the colon says the name is a composer rather than
# merely a word in a title.
_COMPOSER_PREFIX_RE = re.compile(r"^\s*([^:]{2,40}?)\s*:\s*\S")


def _match_composer(text: str) -> str | None:
    """A composer named anywhere in `text`, matched on word boundaries.

    **Never a substring**, which is the whole reason this is a regex per name
    rather than an `in` test: `Bach` occurs inside `Bacharach`, and a library
    with one Burt Bacharach track would otherwise credit the St Matthew Passion
    to him. The same rule `Ontology.domainForCreatorTag` follows for tags.
    """
    if not text:
        return None
    for surname, canonical in CLASSICAL_COMPOSERS.items():
        if re.search(r"\b" + re.escape(surname) + r"\b", text, re.IGNORECASE):
            return canonical
    return None


def _composer_as_prefix(text: str) -> str | None:
    """A composer named as the whole `Composer:` prefix, not merely inside it.

    **The loose version read a movement marker as a composer.** It searched the
    entire prefix — up to forty characters — so `Johannes-Passion, BWV 245,
    Part II` matched `Part`, and the resulting strip left `classical_work`
    unable to find the catalogue number it was standing next to.
    `Glass`, `Reich`, `Berg` and `Ives` are the same hazard waiting.
    
    A real prefix is the composer and nothing else: `Bach: Matthäus-Passion`,
    `Brahms: Double Concerto`, `Beethoven: Pathétique & Moonlight Sonatas`. So
    the test is equality after trimming rather than a search, which removes the
    whole class rather than the one instance that was caught.
    """
    prefix = _COMPOSER_PREFIX_RE.match(text)
    if not prefix:
        return None
    candidate = prefix.group(1).strip()
    for surname, canonical in CLASSICAL_COMPOSERS.items():
        if candidate.casefold() == surname.casefold():
            return canonical
    return None


def classical_composer(title: str, album: str, stated: str = "") -> str | None:
    """The composer of a classical row, in descending confidence.

    Four passes, and the order is the argument:

    1. **What Apple stated.** Present on only ~8% of a real classical library,
       and still the best answer where it exists.
    2. **A `Composer: Work` prefix** on the title or album. The colon is what
       makes this strong — `Beethoven: Pathétique` asserts the name is the
       composer, where a bare mention does not.
    3. **A catalogue number.** `BWV 244` identifies Bach the way an ISBN
       identifies a book. Ambiguous prefixes are absent from the table rather
       than guessed, so `Op. 13` falls through to nothing here.
    4. **A composer named anywhere in the album.** `The Very Best of
       Shostakovich` has no colon and is unmistakable. Weakest of the four
       because it is the one that could be a coincidence, so it runs last.

    Returns `None` rather than a guess. An unattributed row keeps its performer
    and gains no composer, which is the same abstention this module already
    makes for a work it cannot name.
    """
    if stated.strip():
        return resolve_name(stated.strip()) or stated.strip()

    for text in (title, album):
        found = _composer_as_prefix(text or "")
        if found:
            return found

    catalogue = _CATALOGUE_RE.search(title or "")
    if catalogue:
        composer = CATALOGUE_COMPOSERS.get(catalogue.group(1))
        if composer:
            return composer

    return _match_composer(album or "")


def classical_work(title: str) -> str | None:
    """The piece a movement belongs to, cut at its catalogue number.

    `Matthäus-Passion, BWV 244, Seconda parte: Nr.38. Petrus aber saß draußen`
    becomes `Matthäus-Passion, BWV 244`. Sixty-eight movement rows collapse onto
    one work, which is the thing a listener would say they listened to — the
    owner of the measured library put it as caring about the piece and not about
    which choir performed it.

    **The catalogue number is the cut point because it is unambiguous.** Cutting
    at the first colon would take `Chopin` off `Chopin: Polonaise…` and cutting
    at the last would keep `Seconda parte`. A catalogue number ends the work's
    name by convention and begins nothing else.

    A leading `Composer: ` is stripped first, so the work is the piece rather
    than the attribution. Returns `None` when there is no catalogue number: a
    title with no such marker cannot be cut safely, and inventing a boundary is
    how `Bleach: Thousand-Year Blood War` once collected 139 unrelated albums.
    """
    if not title:
        return None
    text = title
    prefix = _COMPOSER_PREFIX_RE.match(text)
    if prefix and _composer_as_prefix(text):
        text = text[prefix.end(1):].lstrip(": ").strip()

    catalogue = _CATALOGUE_RE.search(text)
    if not catalogue:
        return None
    work = text[:catalogue.end()].strip().rstrip(",;:").strip()
    return work or None
