#!/usr/bin/env python3
"""Vocabulary for the domains this ontology has never held, imported by slice.

**Why this exists.** Measured 2026-08-15 over the published ontology: 1,616
creators (almost all Apple Music artists), 109 genres (music), 53 activities
(sports, workouts and named trips) and 45 works. Ask it about the NBA, League of
Legends, Messi, archaeology, architecture, pottery or Cubism and it holds one of
the seven — `NBA`, already an alias of `activity:basketball` since `0145`.

`semantic_private.observation_mentions` says the same thing from the other side:
65,398 mentions across 2,076 distinct strings that resolved to nothing.

**No egress, which is a decision and not a limitation.** The resolver does not
and will not call out: `allow_external_resolution` is written `false` by
ingestion and six projection guards refuse a row where it is not, an external
hit is permanently `CANDIDATE` and never evidence, and no provider is
constructed in `resolve.py`. This tool runs on a laptop instead, and the
distinction that makes that honest is that **the query names the slice, never a
user's string**. The demand list is read locally to decide *which* slice is
worth importing; `matthäus passion bwv 244` never leaves the database.

**It reuses `WikidataProvider` for transport**, rather than opening a second
client — the rate limit, the 429 retry, the response-size cap and the
User-Agent are all there and were all written for the same endpoint. What it
does *not* reuse is that class's projection: `_cache_projection` keeps aliases
in one language and discards labels entirely, which is right for resolving one
term and useless for minting vocabulary.

**Two requests per entity at most, and structure comes from SPARQL.** Asking
`Special:EntityData` for a well-known person returns megabytes and would trip
the size cap; the query service answers the same structural questions — id,
label, description, parent, sitelink count — in one compact response for a whole
slice. Aliases then come from `wbgetentities`, which takes fifty ids at a time
and can be asked for `aliases|labels` alone.

**Notability is a sitelink count**, the same shape as the subscriber count in
`0195`: a number the source states, never a label we invent. It is set per
slice from what the slice returns, and printed, because a silent cut reads as
"this is everything there is".

    python3 tools/wikidata_vocab.py --probe     # do the queries reach the examples?
    python3 tools/wikidata_vocab.py --review    # a table for a person to read
    python3 tools/wikidata_vocab.py > payload.json

Nothing here reads or writes a database, and it deliberately does not know what
the vocabulary already holds — that question is answered in SQL, against live
rows, by the migration this feeds. The output is a payload for review, exactly
as `tools/apple_genres.py` feeds `0189`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
from dataclasses import dataclass, field
from typing import Any

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "semantic" / "src"))

from written_ontology.normalize import normalize_text  # noqa: E402
from written_ontology.providers.wikidata import (  # noqa: E402
    _INSTANCE_KIND,
    WikidataProvider,
)
from written_ontology.safety import (  # noqa: E402
    PROHIBITED_INFERRED_KINDS,
    PROHIBITED_KEY_FRAGMENTS,
)

SPARQL_ENDPOINT = "https://query.wikidata.org/sparql"
ENTITY_API = "https://www.wikidata.org/w/api.php"

# A real contact address, because the constructor refuses a placeholder and
# Wikidata's user-agent policy asks for one. This is the project's published
# address, which is already on every page of the website.
USER_AGENT = "WrittenOntologyImport/0.1 (https://written-stl.com; hello@written-stl.com)"

# Alias languages: the ones the vocabulary already speaks. `0145` holds `ja`,
# `ko`, `zh` and `it` labels, and the YouTube tags that drove `0196` were Korean
# and Japanese. Asking for more would mint spellings nothing will ever match.
ALIAS_LANGUAGES = ("en", "ja", "ko", "zh")

# **Six labels per concept, and the cap is a safety rule rather than a size
# one.** Wikidata offers eight aliases per language in four languages; taking
# them all gave 11,544 strings across 1,397 concepts, and every one of those is
# matching surface that nobody has read. `0196` added 1,489 aliases and that was
# a migration's worth of argument on its own. The preferred label is always
# kept; the rest are taken in the order Wikidata ranks them, which puts the
# common spellings first.
MAX_LABELS_PER_CONCEPT = 6

# **The five topics that must never become vocabulary, whatever a slice
# returns.** These are `Modality.refusedTopics` — dropped from YouTube's own
# category list *"whatever YouTube says"*, because a content tag is how a
# protected characteristic arrives without anybody deciding to collect it. The
# academic-discipline slice reaches them honestly: Health, Religion, Politics and
# Society are all fields of study.
#
# **The refusal is of the container, not of every field inside it.**
# `subject:medicine` has been in this vocabulary since `0134` and stays: it names
# a discipline. `subject:health` names the whole area, and somebody's health is
# the thing this product may not infer. The same distinction `PROJECT-CONTEXT`
# draws about `genre:asian_music` being "a container in all but name".
#
# Found by the migration, not by this file: `subject:health` reached the assert
# and rolled back a 724-concept import. The check belongs at both ends.
REFUSED_TOPIC_LABELS = frozenset({"religion", "politics", "health", "military", "society"})

_SLUG_STRIP = re.compile(r"[^a-z0-9]+")
_QID = re.compile(r"^Q\d+$")

# Words that must never become an alias on their own, because a tag or a title
# containing them says nothing. The same judgement `0196` made about `sakura`
# and `games_concepts.csv` made about `wow`, applied up front rather than after
# a bad match.
UNSAFE_ALIASES = frozenset(
    {
        "art", "ball", "big", "book", "boxing", "class", "club", "code", "cup",
        "dance", "design", "ドラマ", "film", "fire", "game", "games", "go",
        "gold", "history", "home", "ice", "law", "life", "light", "live",
        "love", "man", "map", "media", "mix", "modern", "music", "new", "one",
        "open", "pop", "power", "pro", "run", "school", "science", "set",
        "show", "sound", "space", "sport", "sports", "star", "story", "study",
        "style", "sun", "test", "the", "time", "top", "tour", "war", "water",
        "way", "web", "wild", "work", "world",
    }
)


# **Six proposals name something the vocabulary already holds under another
# name, and each is authored rather than guessed.** Measured across all 1,408
# proposals against every existing `activity:`, `subject:` and `concept:` label:
# these six and no others carry a label already owned by a different concept.
#
# Minting them anyway would split one interest across two concepts — Messi
# hanging from `activity:association_football` while every existing row calls it
# `activity:soccer`, and the evidence for one never reaching the other. The key
# is rewritten to the one we already have, which turns the proposal into an
# alias contribution: `association football` becomes a spelling of Soccer.
#
# This is a *judgement list* and is meant to stay short. A seventh case is a
# question for a person, not a line to add reflexively.
MERGE_INTO = {
    "activity:association_football": "activity:soccer",
    "activity:competitive_swimming": "activity:swimming",
    "activity:rugby_union": "activity:rugby",
    "subject:computer_programming": "subject:programming",
    "subject:technology": "concept:technology",
    # Humour is not an art movement in any sense this product means; the
    # existing `concept:humour` is what a person would recognise.
    "movement:humour": "concept:humour",
}


@dataclass(frozen=True)
class Slice:
    """One domain, one query, one place everything in it hangs from.

    `parent_key` fixed means every concept in the slice hangs from the same hub.
    `parent_property` instead means the parent is read off the entity — used for
    athletes, where hanging every one of them from `hub:sports_movement`
    directly would lose the fact that says which sport, and where a person whose
    sport we do not hold is dropped rather than parented to a guess.
    """

    name: str
    kind: str
    prefix: str
    minimum_sitelinks: int
    # **Either a hand-written pattern, or a seed resolved from our own
    # vocabulary.** `where` is the older form and names a Wikidata class by QID,
    # which means somebody had to go and find that QID — prior knowledge, and a
    # new one needed for every medium. `seed_label` is the newer form and needs
    # none: it takes a word this ontology already uses, resolves it to a Wikidata
    # entity by ordinary search, and asks for works of that genre or that type.
    #
    # **Measured, and the seed wins.** Hand-picked `Q63952888` (anime television
    # series) returned 501 entities above ten sitelinks; seeding the word `anime`
    # resolves `Q1107` and returns **914**, because `P31/P279*` reaches anime
    # films and OVAs that the hand-picked class excludes. The general rule beat
    # the specific knowledge.
    where: str = ""
    seed_label: str = ""
    parent_key: str | None = None
    parent_property: str | None = None
    limit: int = 400
    notes: str = ""
    # Lower wins when one entity satisfies two slices. **Measured, not
    # anticipated**: the first run put 40 entities in two slices at once, all of
    # them video games that Wikidata also models as a type of sport, so League of
    # Legends became `activity:league_of_legends` *and* `work:league_of_legends`
    # and the ambiguity rule below then refused both. A duplicate is not an
    # ambiguity, and the more specific selector is the right one — `instance of
    # video game` over a subclass walk from `type of sport`.
    precedence: int = 50


# **The slices, in the order the owner asked for: breadth before depth.**
#
# Each `where` is a graph pattern over `?item`, and every query adds the
# sitelink bound, the label service and the limit — so a slice is one honest
# line about what it selects rather than a hand-written query per domain.
SLICES: tuple[Slice, ...] = (
    Slice(
        name="sports",
        kind="activity",
        prefix="activity:",
        minimum_sitelinks=60,
        # **Esports excluded here rather than sorted out afterwards.** Wikidata
        # models a competitive title as a subclass of `type of sport`, which is
        # true of the competition and false of the thing somebody plays. The
        # precedence rule below would catch it anyway; excluding it in the query
        # means the two mechanisms disagree about nothing.
        where=(
            "?item wdt:P31/wdt:P279* wd:Q31629 . "
            "FILTER NOT EXISTS { ?item wdt:P31 wd:Q7889 }"
        ),
        parent_key="hub:sports_movement",
        notes="type of sport (Q31629), not video games",
        precedence=60,
    ),
    # ARCHIVED-ATHLETES — removed 2026-08-15, and the reason generalises.
    #
    #     Slice(name="athletes", kind="creator", prefix="creator:",
    #           minimum_sitelinks=130, parent_property="parent", limit=600,
    #           where="?item wdt:P31 wd:Q5 . ?item wdt:P641 ?parent .")
    #
    # **A sitelink count cannot say "notable *as* an athlete".** It measures how
    # many Wikipedias wrote about a person at all, so at any bound high enough to
    # be selective it returns the most famous humans who happen to have a sport
    # recorded — the run that caught this proposed **Plato** (Greek wrestling),
    # **Joe Biden**, **George H. W. Bush** and **Gerald Ford** (American
    # football), and Plato is the one that tripped the migration's no-parent
    # assertion. Adding `?item wdt:P106/wdt:P279* wd:Q2066131` did not fix it:
    # George W. Bush, Albert Camus, Henry Ford and Charles III all carry a
    # sportsperson occupation and survived. The next step would have been
    # excluding politicians, philosophers and writers by occupation, which is a
    # deny-list, and **the failure mode of a deny-list is silence** — plus it
    # timed the query service out.
    #
    # **Why the bound works for the other five and not for this one:** a sport, a
    # game, a discipline, an art movement and a craft have no fame except their
    # own, so sitelinks measure the thing itself. A person has fame from
    # everything they ever did, and this slice needed the part of it that came
    # from sport. That is the test for any future person-shaped slice.
    #
    # It costs Messi, who is a real example somebody asked for. A correct version
    # needs a notability signal that is *about the sport* — sports-team
    # membership, competition results, a career-appearances statement — not a
    # louder version of fame. The `parent_property` machinery stays because that
    # is the half that worked.
    Slice(
        name="games",
        kind="work",
        prefix="work:",
        minimum_sitelinks=35,
        where="?item wdt:P31 wd:Q7889 .",
        parent_key="hub:games_play",
        notes="video game (Q7889)",
        precedence=10,
    ),
    # **The four media a song can come *from*, seeded from our own genres.**
    #
    # `music_works.py` already derives the source work — `From "X"` on the title
    # or album, a stripped soundtrack album, a propagated sibling — and it is the
    # dominant path to a work concept: **1,380 of 1,431 work mappings** carry a
    # `source_work` evidence role. What it lacks is somewhere to land. Measured
    # 2026-08-15: **32 shows named by Apple and resolving to nothing**, 500
    # mentions.
    #
    # **Which media, decided by the data rather than by me.** The genres on the
    # rows whose `source_work` failed are `soundtrack` (25 observations), `anime`
    # (11) and `musicals` (9). The first of those is why film and television are
    # here: a soundtrack genre says the song came from something without saying
    # what, and seeding the word `soundtrack` resolves to Q217199 and returns
    # *Arthur Honegger* — a composer. So the medium seeds stand in for it, and
    # that substitution is the one judgement in this block.
    #
    # **Anime is deliberately the largest.** Six of the unresolved shows are
    # anime and three are written in Japanese — `オーバーロードii` is `work:overlord_ii`,
    # a concept we already hold with no `ja` label on it. For those the slice
    # buys aliases rather than concepts, which is the cheaper half of the same
    # fix.
    Slice(
        name="musicals",
        kind="work",
        prefix="work:",
        minimum_sitelinks=10,
        seed_label="musical",
        parent_key="genre:musicals",
        notes="seeded from genre:musicals",
        limit=200,
        precedence=11,
    ),
    Slice(
        name="anime",
        kind="work",
        prefix="work:",
        minimum_sitelinks=10,
        seed_label="anime",
        parent_key="genre:anime",
        notes="seeded from genre:anime",
        limit=350,
        precedence=12,
    ),
    Slice(
        name="films",
        kind="work",
        prefix="work:",
        # **Films need a far higher bar than musicals for the same selectivity.**
        # 25,011 films clear ten sitelinks against 110 musicals, because the
        # medium is that much larger — so the bound is a property of the slice
        # rather than a constant, and it is printed for that reason.
        minimum_sitelinks=60,
        seed_label="film",
        parent_key="hub:film_video",
        notes="seeded from hub:film_video",
        limit=250,
        precedence=13,
    ),
    Slice(
        name="television",
        kind="work",
        prefix="work:",
        minimum_sitelinks=40,
        seed_label="television series",
        parent_key="hub:film_video",
        notes="seeded from hub:film_video",
        limit=200,
        precedence=14,
    ),
    Slice(
        name="disciplines",
        kind="topic",
        prefix="subject:",
        minimum_sitelinks=60,
        where="?item wdt:P31/wdt:P279* wd:Q11862829 .",
        parent_key="hub:ideas_learning",
        notes="academic discipline (Q11862829)",
        precedence=40,
    ),
    Slice(
        name="movements",
        kind="topic",
        prefix="movement:",
        minimum_sitelinks=40,
        where="?item wdt:P31/wdt:P279* wd:Q968159 .",
        parent_key="hub:arts_live",
        notes="art movement (Q968159)",
        precedence=30,
    ),
    Slice(
        name="crafts",
        kind="activity",
        prefix="activity:",
        minimum_sitelinks=20,
        where="?item wdt:P31/wdt:P279* wd:Q2207288 .",
        parent_key="hub:work_study_making",
        notes="craft (Q2207288)",
        precedence=20,
    ),
    # **The heading slices (owner, 2026-08-25): categories the model may
    # select and may never invent.** The v19 proposal pass measured what
    # open-vocabulary category generation produces — "Chinese pop music",
    # "C-pop" and "Mandopop songs" as three mintable headings for one
    # concept-space, "Songs" and "Music albums" as headings at all — and the
    # owner's direction is the person-subtype method applied to headings:
    # pre-emptively mint the recognised category system from one curated CC0
    # source, then the model only chooses. The measured holes, 2026-08-25:
    # `hub:film_video` had **zero** authored sub-headings (why every series
    # hub-dumped), `hub:games_play` five, `hub:music` only Apple's 104.
    #
    # **A genre's fame is its own**, like a sport's and unlike an athlete's —
    # the sitelink bound measures the thing itself, so the athletes failure
    # mode does not apply.
    #
    # **Corrected 2026-08-25: the walk is the default, and the floor is the
    # depth guard.** The first cut used direct `P31` on the reasoning that
    # `P279*` reaches microgenres — half-right, and the measured cost was the
    # whole regional tier: Peking opera is `instance of: opera genre`, a
    # subclass, so the direct fetch left Kunqu, Peking and Yue opera invisible
    # while a corpus full of them refused every heading. The cuisines slice
    # had already learned this (Italian cuisine is an instance of *national
    # cuisine*); the genre slices refused the same lesson. A microgenre nobody
    # writes about falls below any floor; Peking opera does not.
    Slice(
        name="music_genres",
        kind="genre",
        prefix="genre:",
        minimum_sitelinks=25,
        where="?item wdt:P31/wdt:P279* wd:Q188451 .",
        parent_key="hub:music",
        notes="music genre (Q188451), subclass walk for the regional tier",
        precedence=25,
    ),
    Slice(
        name="film_genres",
        kind="genre",
        prefix="genre:",
        minimum_sitelinks=20,
        where="?item wdt:P31/wdt:P279* wd:Q201658 .",
        parent_key="hub:film_video",
        notes="film genre (Q201658), subclass walk",
        precedence=26,
    ),
    Slice(
        name="tv_genres",
        kind="genre",
        prefix="genre:",
        minimum_sitelinks=15,
        where="?item wdt:P31/wdt:P279* wd:Q15961987 .",
        parent_key="hub:film_video",
        notes="television genre (Q15961987), subclass walk",
        precedence=27,
    ),
    Slice(
        name="game_genres",
        kind="genre",
        prefix="genre:",
        minimum_sitelinks=15,
        where="?item wdt:P31/wdt:P279* wd:Q659563 .",
        parent_key="hub:games_play",
        notes="video game genre (Q659563), subclass walk",
        precedence=28,
    ),
    # **The 2026-08-25 audit's three (owner: "fetch all three").** These parent
    # to `medium:` layer nodes rather than hubs, because 0348 established the
    # layer and a new genre hanging from a bare hub would recreate the state
    # that migration asserts away. The nodes are minted by the same migration
    # that imports these (0349), before the edges land.
    Slice(
        name="cuisines",
        kind="cuisine",
        prefix="cuisine:",
        minimum_sitelinks=25,
        # The subclass walk earns its place here where the genre slices refuse
        # it: `Italian cuisine` is an instance of a *subclass* (national
        # cuisine), and direct P31 on Q1778821 misses the entire national
        # tier — the tier that is the point.
        where="?item wdt:P31/wdt:P279* wd:Q1778821 .",
        parent_key="medium:cuisines",
        notes="cuisine (Q1778821), subclass walk for the national tier",
        precedence=29,
    ),
    Slice(
        name="literary_genres",
        kind="genre",
        prefix="genre:",
        minimum_sitelinks=20,
        where="?item wdt:P31 wd:Q223393 .",
        parent_key="medium:literary_genres",
        notes="literary genre (Q223393)",
        precedence=31,
    ),
    Slice(
        name="theatre_genres",
        kind="genre",
        prefix="genre:",
        # The class the audit skipped — stage had no slice at all, which is
        # half of how three Chinese opera traditions went unrepresented while
        # a corpus full of their recordings refused every heading. The trio
        # must arrive through this rule, never by being typed into a file.
        minimum_sitelinks=12,
        where="?item wdt:P31/wdt:P279* wd:Q7777573 .",
        parent_key="medium:stage_genres",
        notes="theatrical genre (Q7777573), subclass walk",
        precedence=30,
    ),
    Slice(
        name="comics_genres",
        kind="genre",
        prefix="genre:",
        # Lower than the screen slices: shonen and isekai live here, and manga
        # genres run fewer Wikipedias than film genres at the same renown.
        minimum_sitelinks=10,
        where=("{ ?item wdt:P31 wd:Q20087698 . } "
               "UNION { ?item wdt:P31 wd:Q103112098 . }"),
        parent_key="medium:comics_manga_genres",
        notes="comic genre (Q20087698) + manga genre (Q103112098)",
        precedence=32,
    ),
)

# The examples the owner named, and the probe that says whether the slices above
# actually reach them. A slice definition is a guess until this passes.
PROBE_EXAMPLES = {
    "Q155223": "NBA",
    "Q223341": "League of Legends",
    "Q615": "Lionel Messi",
    "Q23498": "archaeology",
    "Q12271": "architecture",
    "Q11642": "pottery",
    "Q42934": "Cubism",
}



def kind_contradicts(slice_kind: str, types: set[str]) -> str | None:
    """Does the entity's own type say it is something else?

    **A contradiction test, not a requirement.** `_INSTANCE_KIND` in the
    provider maps eight Wikidata classes onto our kinds and knows nothing about
    the rest, so demanding a *match* would refuse almost everything — an anime
    television series is in no such map. Demanding merely that it does not say
    the opposite is what the map can actually support.

    **Written after the musicals slice returned Cole Porter.** Seeding a genre
    finds humans as readily as works: `P136 = musical play` is a statement made
    about Irving Berlin, Idina Menzel and Lin-Manuel Miranda, and 269 humans
    carry it. Every one would have been minted as `work:cole_porter`. This is
    the athletes lesson arriving from a different direction — a slice that
    returns the wrong *kind* of thing rather than the wrong *fame* of thing.

    The map is the provider's, reviewed and tested there, so no new class id is
    introduced here.
    """
    for type_qid in types:
        derived = _INSTANCE_KIND.get(type_qid)
        if derived and derived != slice_kind:
            return derived
    return None

def slug(label: str) -> str:
    """A concept key's tail: ASCII, lowercase, underscore-joined.

    Every key in this ontology is romanised — `creator:fanzheng_wo_hen_xian`
    holds a Chinese name under a Latin key — so a label that leaves nothing
    behind here has no key and is reported rather than minted under a
    fallback. **A constant fallback key once merged nine artists into one
    concept**, and that is the failure this refuses to repeat.
    """
    return _SLUG_STRIP.sub("_", normalize_text(label)).strip("_")


def sparql(query: str, provider: WikidataProvider) -> list[dict[str, Any]]:
    url = f"{SPARQL_ENDPOINT}?{urllib.parse.urlencode({'query': query, 'format': 'json'})}"
    payload = provider._get_json(url)
    return payload.get("results", {}).get("bindings", [])


# Resolved seeds, so one label costs one lookup however many slices use it, and
# so the run can report which entity it actually chose.
_SEEDS: dict[str, str] = {}


def seed_entity(label: str, provider: WikidataProvider) -> str:
    """A word this ontology already uses, resolved to a Wikidata entity.

    **This is what replaces knowing a QID.** The seed is *our* vocabulary —
    `genre:musicals` is called "musical", `genre:anime` is called "anime" — so
    adding a genre to the ontology brings its slice with it, and nobody has to
    go and look up what Wikidata calls the class this time.

    **It is not a user's string.** The demand list is read locally to decide
    *which* of our genres is worth seeding; the word that leaves is the one in
    our own concept table, which is the same word for every install.

    The first search hit is taken and **reported in the payload**, because a
    seed that resolved to the wrong entity is the one way this can go quietly
    wrong — `soundtrack` resolves to Q217199 and returns a composer, which is
    how that slice came to be dropped.
    """
    if label in _SEEDS:
        return _SEEDS[label]
    url = f"{ENTITY_API}?" + urllib.parse.urlencode({
        "action": "wbsearchentities", "format": "json", "search": label,
        "language": "en", "type": "item", "limit": 1,
    })
    hits = provider._get_json(url).get("search", [])
    if not hits or not _QID.fullmatch(hits[0].get("id", "")):
        raise SystemExit(f"no Wikidata entity for the seed label {label!r}")
    _SEEDS[label] = hits[0]["id"]
    print(f"  seed {label!r} -> {hits[0]['id']} ({hits[0].get('label')})", file=sys.stderr)
    return _SEEDS[label]


def slice_query(item: Slice, where: str) -> str:
    """One slice, plus the two things every slice needs: a bound and a name.

    **The English Wikipedia title is asked for alongside the label, and it is not
    a nicety.** Wikidata frequently stores no `en` *label* for a work whose name
    is already the title of its English Wikipedia article — **Minecraft** has 43
    labels and 156 sitelinks and no English one, and so do Grand Theft Auto V and
    88 other games in this slice: **90 of 304, all silently dropped** by the
    first run, because the label service answers with the bare QID and minting
    `Q49740` as somebody's interest would be worse than missing it.

    The article title is a name the source states, in the language we want, so it
    is a fallback rather than an invention.
    """
    parent_select = " ?parent ?parentLabel" if item.parent_property else ""
    return f"""
SELECT ?item ?itemLabel ?itemDescription ?sitelinks ?enwiki ?type{parent_select} WHERE {{
  {where}
  OPTIONAL {{ ?item wdt:P31 ?type . }}
  ?item wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks >= {item.minimum_sitelinks})
  OPTIONAL {{
    ?article schema:about ?item ;
             schema:isPartOf <https://en.wikipedia.org/> ;
             schema:name ?enwiki .
  }}
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en". }}
}}
ORDER BY DESC(?sitelinks)
LIMIT {item.limit}
"""


# An article title carries a disambiguator the label would not — "Cluedo (video
# game)", "Mercury (planet)". Stripping one trailing parenthetical is what makes
# the title usable as a name; anything more elaborate would be guessing.
_TRAILING_PAREN = re.compile(r"\s*\([^()]*\)\s*$")


def name_from(row: dict[str, Any]) -> str:
    label = row.get("itemLabel", {}).get("value", "")
    if label and not _QID.fullmatch(label):
        return label
    article = row.get("enwiki", {}).get("value", "")
    return _TRAILING_PAREN.sub("", article).strip()


def slice_pattern(item: Slice, provider: WikidataProvider) -> list[str]:
    """The graph pattern for a slice: written out, or built from a seed.

    A seeded slice asks for both readings, because Wikidata uses both and which
    one a medium uses is exactly the prior knowledge this avoids needing:
    `P136` for a work *of* that genre, `P31/P279*` for a work that *is* one.
    """
    if item.seed_label:
        qid = seed_entity(item.seed_label, provider)
        # **Two queries rather than one UNION**, because the UNION times the
        # query service out on a large medium: films are 25,011 entities above
        # ten sitelinks and the planner evaluates the whole pattern before the
        # filter bites. Split, each half is cheap, and merging them here costs
        # one extra request per slice.
        return [f"?item wdt:P136 wd:{qid} .",
                f"?item wdt:P31/wdt:P279* wd:{qid} ."]
    return [item.where]


def fetch_slice(item: Slice, provider: WikidataProvider) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for pattern in slice_pattern(item, provider):
        try:
            rows += sparql(slice_query(item, pattern), provider)
        except Exception as refusal:
            # **A reading that times out is reported, never swallowed.** One of
            # the two halves failing would otherwise look like a medium with
            # fewer works in it than it has.
            print(f"  {item.name}: a reading failed ({type(refusal).__name__}), "
                  f"the slice is incomplete", file=sys.stderr)
    entities: dict[str, dict[str, Any]] = {}
    for row in rows:
        qid = row.get("item", {}).get("value", "").rsplit("/", 1)[-1]
        if not _QID.fullmatch(qid):
            continue
        # The label, or the English Wikipedia title where Wikidata holds no
        # English label. An entity with neither has no name we can use and is
        # skipped: minting `Q49740` as somebody's interest is worse than missing
        # it.
        label = name_from(row)
        if not label or _QID.fullmatch(label):
            continue
        record = entities.setdefault(
            qid,
            {
                "qid": qid,
                "label": label,
                "description": row.get("itemDescription", {}).get("value") or None,
                "sitelinks": int(row.get("sitelinks", {}).get("value", 0)),
                "parents": [],
                "types": set(),
            },
        )
        type_qid = row.get("type", {}).get("value", "").rsplit("/", 1)[-1]
        if _QID.fullmatch(type_qid):
            record["types"].add(type_qid)
        if item.parent_property:
            parent_qid = row.get("parent", {}).get("value", "").rsplit("/", 1)[-1]
            parent_label = row.get("parentLabel", {}).get("value", "")
            if _QID.fullmatch(parent_qid) and parent_label and not _QID.fullmatch(parent_label):
                record["parents"].append({"qid": parent_qid, "label": parent_label})
    return sorted(entities.values(), key=lambda row: (-row["sitelinks"], row["qid"]))


def fetch_aliases(qids: list[str], provider: WikidataProvider) -> dict[str, list[dict[str, str]]]:
    """Aliases and labels, fifty ids per request, in the languages we speak."""
    out: dict[str, list[dict[str, str]]] = {}
    for start in range(0, len(qids), 50):
        batch = qids[start : start + 50]
        url = f"{ENTITY_API}?" + urllib.parse.urlencode(
            {
                "action": "wbgetentities",
                "format": "json",
                "ids": "|".join(batch),
                "props": "labels|aliases",
                "languages": "|".join(ALIAS_LANGUAGES),
            }
        )
        payload = provider._get_json(url)
        for qid, entity in payload.get("entities", {}).items():
            collected: list[dict[str, str]] = []
            for language in ALIAS_LANGUAGES:
                label = entity.get("labels", {}).get(language, {}).get("value")
                if label:
                    collected.append({"value": label, "locale": language})
                for alias in entity.get("aliases", {}).get(language, [])[:8]:
                    value = alias.get("value")
                    if value:
                        collected.append({"value": value, "locale": language})
            out[qid] = collected
    return out


def alias_is_usable(value: str) -> bool:
    normalized = normalize_text(value)
    # `MIN_TAG_LENGTH` at the other end is 3, and a one- or two-character alias
    # matches everywhere. A bare common word matches everywhere too. And a
    # refused topic is refused as an alias on anything, not only as a name of
    # its own — `society` hung on a sociology concept makes it resolvable just
    # the same.
    return (
        len(normalized) >= 3
        and normalized not in UNSAFE_ALIASES
        and normalized not in REFUSED_TOPIC_LABELS
    )


def build(provider: WikidataProvider) -> dict[str, Any]:
    """Propose vocabulary. What we already hold is not this tool's question.

    **The database decides what is already in the vocabulary, not a file.** An
    earlier draft took a dumped list of existing keys, and that list is stale the
    moment any other migration mints a concept — it would have proposed a
    duplicate and blamed the tool's own snapshot. So the collision check lives in
    the migration, against live rows, and the parent of an athlete is emitted as
    a *candidate slug* for SQL to resolve: `activity:basketball` has been in the
    vocabulary since `0145` and carries no QID anything here could join on.
    """
    proposals: list[dict[str, Any]] = []
    refusals: list[dict[str, Any]] = []
    # QID -> the key this run proposes for it, so a slice can parent onto one
    # minted by an earlier slice in the same run.
    qid_to_key: dict[str, str] = {}
    # QID -> the slice that has claimed it, so one entity becomes one concept.
    claimed_by: dict[str, Slice] = {}

    for item in sorted(SLICES, key=lambda s: s.precedence):
        rows = fetch_slice(item, provider)
        aliases = fetch_aliases([row["qid"] for row in rows], provider)
        minted_here = 0
        for row in rows:
            tail = slug(row["label"])
            key = f"{item.prefix}{tail}"
            # Rewritten *before* anything else uses it, so a parent candidate and
            # an ambiguity check both see the key this will really become.
            merged_from = key if key in MERGE_INTO else None
            key = MERGE_INTO.get(key, key)
            reason: str | None = None

            contradiction = kind_contradicts(item.kind, row.get("types") or set())
            if contradiction:
                refusals.append({
                    "slice": item.name, "qid": row["qid"], "label": row["label"],
                    "reason": f"its own type says {contradiction}, not {item.kind}",
                })
                continue

            if row["qid"] in claimed_by:
                # **Reported, never silent.** One entity is one concept, and
                # which slice got it is a decision somebody should be able to
                # read back — a duplicate quietly dropped looks exactly like a
                # query that never matched it.
                reason = f"already claimed by the {claimed_by[row['qid']].name} slice"
            elif normalize_text(row["label"]) in REFUSED_TOPIC_LABELS:
                reason = "the preferred label is a refused topic"
            elif not tail:
                reason = "no ASCII key can be formed from the label"
            elif any(fragment in key for fragment in PROHIBITED_KEY_FRAGMENTS):
                reason = "the key contains a prohibited fragment"
            elif item.kind in PROHIBITED_INFERRED_KINDS:
                reason = f"{item.kind} is a prohibited inferred kind"

            # The parent. A fixed hub for most slices; for athletes it is read
            # off the entity and emitted as candidate keys in preference order,
            # because only the database knows which of them it holds.
            #
            # **A candidate list, never a guess.** A concept with no `broader`
            # edge blocks to null and lands under "Other"; one parented to the
            # wrong sport is a false claim about somebody. The migration takes
            # the first candidate it actually has and refuses the row if it has
            # none — which is the right answer for a handball player when the
            # vocabulary holds no handball.
            parent_candidates: list[str] = []
            if reason is None and item.parent_property:
                for candidate in row["parents"]:
                    mapped = qid_to_key.get(candidate["qid"])
                    if mapped:
                        parent_candidates.append(mapped)
                    candidate_slug = slug(candidate["label"])
                    if candidate_slug:
                        candidate_key = f"activity:{candidate_slug}"
                        parent_candidates.append(MERGE_INTO.get(candidate_key, candidate_key))
                if not parent_candidates:
                    reason = "the entity states no sport that could name a parent"

            if reason is not None:
                refusals.append(
                    {"slice": item.name, "qid": row["qid"], "label": row["label"], "reason": reason}
                )
                continue

            usable = [a for a in aliases.get(row["qid"], []) if alias_is_usable(a["value"])]
            seen: set[str] = set()
            labels = []
            for alias in usable:
                normalized = normalize_text(alias["value"])
                if normalized in seen:
                    continue
                seen.add(normalized)
                labels.append(
                    {
                        "label": alias["value"],
                        "normalized": normalized,
                        "locale": alias["locale"],
                        "label_type": "preferred"
                        if alias["value"] == row["label"] and not labels
                        else "alternate",
                    }
                )
            if not any(entry["label_type"] == "preferred" for entry in labels):
                labels.insert(
                    0,
                    {
                        "label": row["label"],
                        "normalized": normalize_text(row["label"]),
                        "locale": "en",
                        "label_type": "preferred",
                    },
                )

            # Applied last, so the cap is the whole truth about how many labels
            # a concept gets — capping before the preferred label is inserted
            # quietly produces one more than the number written above it.
            labels = labels[:MAX_LABELS_PER_CONCEPT]

            qid_to_key[row["qid"]] = key
            claimed_by[row["qid"]] = item
            minted_here += 1
            proposals.append(
                {
                    "concept_key": key,
                    "preferred_label": row["label"],
                    "concept_kind": item.kind,
                    # **`review_required`, not `inferable`.** Every sport `0134`
                    # authored is `review_required` and the reason generalises:
                    # a watched match implies far less than it looks like it
                    # does, and none of this vocabulary has been seen against
                    # real evidence yet.
                    "inference_policy": "review_required",
                    "sensitivity": "ordinary",
                    "parent_key": item.parent_key,
                    "parent_candidates": list(dict.fromkeys(parent_candidates)),
                    "merged_from": merged_from,
                    # **Provenance, and the hook the engagement distinction will
                    # need.** An activity can be watched or done — soccer, the
                    # violin, pottery — and `ontology.relation_types` already
                    # separates those (`watched`, `completed_activity`,
                    # `attended_activity_at`, `booked_activity_at`), while every
                    # assertion in production is `affinity_to`. Which one applies
                    # is decided by the *evidence*, not by the concept, so
                    # nothing here guesses it; recording the slice and the source
                    # id is what lets a later scorer rule ask "is this a sport?"
                    # without re-deriving it from the key prefix.
                    "metadata": {
                        "source": "wikidata",
                        "external_id": row["qid"],
                        "slice": item.name,
                        "selector": item.notes,
                        "sitelinks": row["sitelinks"],
                        "license": "CC0-1.0",
                    },
                    "slice": item.name,
                    "qid": row["qid"],
                    "sitelinks": row["sitelinks"],
                    "description": row["description"],
                    "labels": labels,
                }
            )
        print(
            f"{item.name:12s} {item.notes:32s} "
            f">= {item.minimum_sitelinks:3d} sitelinks  "
            f"{len(rows):4d} fetched  {minted_here:4d} proposed",
            file=sys.stderr,
        )

    # **Two entities, one key, and neither is minted.** Measured: six keys where
    # the slices found two distinct entities of the same name — two games called
    # Tomb Raider, two senses of modernism, two Venetian schools. Taking either
    # would file one entity's evidence under the other's concept, and there is
    # nothing in the data that says which was meant. The same judgement as the
    # label rule below, one level up, and the reason `0173` records that a
    # fallback key must not be able to collide.
    by_key: dict[str, list[dict[str, Any]]] = {}
    for proposal in proposals:
        by_key.setdefault(proposal["concept_key"], []).append(proposal)
    colliding = {
        key
        for key, group in by_key.items()
        if len({p["qid"] for p in group}) > 1 and not any(p["merged_from"] for p in group)
    }
    for key in colliding:
        for proposal in by_key[key]:
            refusals.append(
                {
                    "slice": proposal["slice"],
                    "qid": proposal["qid"],
                    "label": proposal["preferred_label"],
                    "reason": f"two entities claim the key {key}",
                }
            )
    proposals = [p for p in proposals if p["concept_key"] not in colliding]

    # **Ambiguity refuses, and it refuses both ways.** Two entities producing the
    # same normalized label mint neither — a label that names two things resolves
    # to nothing at the other end anyway, and the resolver's own rule is to
    # refuse an ambiguous label rather than pick.
    by_normalized: dict[str, list[str]] = {}
    for proposal in proposals:
        for entry in proposal["labels"]:
            by_normalized.setdefault(entry["normalized"], []).append(proposal["concept_key"])
    ambiguous = {text for text, keys in by_normalized.items() if len(set(keys)) > 1}
    for proposal in proposals:
        dropped = [e for e in proposal["labels"] if e["normalized"] in ambiguous]
        proposal["labels"] = [e for e in proposal["labels"] if e["normalized"] not in ambiguous]
        for entry in dropped:
            refusals.append(
                {
                    "slice": proposal["slice"],
                    "qid": proposal["qid"],
                    "label": entry["label"],
                    "reason": "the label names more than one proposed concept",
                }
            )

    # A concept whose every label was ambiguous can never be resolved to, so it
    # is not vocabulary.
    keepable = [p for p in proposals if p["labels"]]
    for proposal in proposals:
        if not proposal["labels"]:
            refusals.append(
                {
                    "slice": proposal["slice"],
                    "qid": proposal["qid"],
                    "label": proposal["preferred_label"],
                    "reason": "every label was ambiguous",
                }
            )

    return {
        "source": "wikidata",
        "license": "CC0-1.0",
        "slices": [
            {"name": s.name, "kind": s.kind, "minimum_sitelinks": s.minimum_sitelinks,
             "selector": s.notes, "parent": s.parent_key or f"read from {s.parent_property}"}
            for s in SLICES
        ],
        "concepts": keepable,
        "refusals": refusals,
    }


def probe(provider: WikidataProvider) -> int:
    """Do the slice definitions actually reach the examples that motivated them?

    A slice is a guess until this answers. Run before trusting any output: a
    query that silently selects the wrong branch of the taxonomy produces a
    perfectly well-formed proposal for the wrong vocabulary.
    """
    found: dict[str, str] = {}
    for item in SLICES:
        for row in fetch_slice(item, provider):
            if row["qid"] in PROBE_EXAMPLES:
                found[row["qid"]] = f"{item.name} ({row['sitelinks']} sitelinks)"
    missing = 0
    for qid, name in PROBE_EXAMPLES.items():
        where = found.get(qid)
        print(f"  {name:22s} {qid:10s} {where or 'NOT REACHED BY ANY SLICE'}", file=sys.stderr)
        if where is None:
            missing += 1
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true", help="check the slices reach the examples")
    parser.add_argument("--only", help="comma-separated slice names, for a focused payload")
    parser.add_argument("--review", action="store_true", help="a table for a person to read")
    args = parser.parse_args()

    # **The defaults are the resolver's and are wrong here.** They budget ten
    # seconds and two megabytes for one term lookup; a slice query runs against
    # the whole graph and returns hundreds of rows, so the query service takes
    # tens of seconds and answers with megabytes. Raised for this process only —
    # the class default is what production would use if it ever ran, and it is
    # not this tool's business to relax it there.
    provider = WikidataProvider(
        user_agent=USER_AGENT,
        minimum_request_interval_seconds=1.0,
        timeout_seconds=180.0,
        maximum_response_bytes=32_000_000,
    )

    if args.probe:
        return 1 if probe(provider) else 0

    if args.only:
        wanted = {name.strip() for name in args.only.split(",") if name.strip()}
        unknown = wanted - {s.name for s in SLICES}
        if unknown:
            raise SystemExit(f"no such slice: {', '.join(sorted(unknown))}")
        globals()["SLICES"] = tuple(s for s in SLICES if s.name in wanted)

    payload = build(provider)

    if args.review:
        for proposal in payload["concepts"]:
            parent = proposal["parent_key"] or "/".join(proposal["parent_candidates"][:2])
            print(
                f"{proposal['concept_key']:52s} {proposal['concept_kind']:9s} "
                f"{proposal['sitelinks']:5d}  <- {parent:34s} "
                f"{(proposal['description'] or '')[:44]}"
            )
        print(f"\n{len(payload['concepts'])} proposed, {len(payload['refusals'])} refused",
              file=sys.stderr)
        return 0

    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    print(file=sys.stdout)
    print(
        f"\n{len(payload['concepts'])} concept(s) proposed, {len(payload['refusals'])} refused",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
