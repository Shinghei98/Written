#!/usr/bin/env python3
"""The stated medium for work concepts, imported by slice — never by title.

**Why this exists.** Song-versus-film is an identity fact this corpus cannot
derive at the name level: `0461`'s header records three rules that each broke
real cases (a recording verdict swallowed the musicals; a performed-name test
would strip Twilight; a both-parents test catches Mulan). Wikidata states the
medium as `instance of`, which is the same kind of read as `topicDetails` —
the source's own label, never our inference.

**The egress rule is 0198's and it is not relaxed here**: the query names the
slice — films, television series, anime, musicals, songs, singles, albums,
video games — never a user's string. No title from anybody's library leaves
this laptop; the matching against our own vocabulary happens in SQL, in the
migration this feeds.

**Ambiguity refuses, and the refusal is the design.** A name carried by both
sides — a film and a song ("Twilight"), a musical and an album — is emitted
with both families, and the migration stamps nothing for it: the concept
falls back to the block layer exactly as today. Only a name whose every
Wikidata sighting agrees on a side gets a `work_type`.

    python3 tools/wikidata_work_types.py --counts   # bounds check, no fetch
    python3 tools/wikidata_work_types.py > out/work_types.json
"""
from __future__ import annotations

import json
import sys
import urllib.parse

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "semantic" / "src"))

from written_ontology.normalize import normalize_text  # noqa: E402
from written_ontology.providers.wikidata import WikidataProvider  # noqa: E402

SPARQL_ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = "WrittenOntologyImport/0.1 (https://written-stl.com; hello@written-stl.com)"

#: (family, wikidata class, minimum sitelinks). Direct `P31` on purpose — the
#: subclass walk is what made the minting slices rich, and richness is the
#: opposite of what a typing pass wants: a disputed or exotic subtype failing
#: to type is a refusal, which is safe.
SLICES = (
    # >= 6: 91,153 rows at >= 4 is past what one labelled query answers;
    # the bound is capacity, not judgement, and a below-bound film simply
    # stays untyped — a refusal, which is safe.
    ("film",       "Q11424",    6),   # film
    ("anime_film", "Q20650540", 2),   # anime film
    ("tv_series",  "Q5398426",  4),   # television series
    ("anime_tv",   "Q63952888", 2),   # anime television series
    # The musical slice is deliberately absent: P31 Q2743 holds two rows
    # above two sitelinks (stage musicals are typed elsewhere), and the
    # genre:musicals block already places them without it.
    ("song",       "Q7366",     3),   # song
    ("single",     "Q134556",   3),   # single
    ("album",      "Q482994",   4),   # album
    ("video_game", "Q7889",     4),   # video game
)

RECORDING = {"song", "single", "album"}
WATCHABLE = {"film", "anime_film", "tv_series", "anime_tv", "musical"}


def sparql(provider: WikidataProvider, query: str):
    url = f"{SPARQL_ENDPOINT}?{urllib.parse.urlencode({'query': query, 'format': 'json'})}"
    return provider._get_json(url).get("results", {}).get("bindings", [])


def count(provider: WikidataProvider, qid: str, bound: int) -> int:
    rows = sparql(provider, f"""
SELECT (COUNT(?item) AS ?n) WHERE {{
  ?item wdt:P31 wd:{qid} ; wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks >= {bound})
}}""")
    return int(rows[0]["n"]["value"]) if rows else 0


def fetch(provider: WikidataProvider, qid: str, bound: int):
    """Label and English article title, the pair 0198 learned to ask for —
    Minecraft has 156 sitelinks and no English label."""
    return sparql(provider, f"""
SELECT ?item ?itemLabel ?enwiki ?sitelinks WHERE {{
  ?item wdt:P31 wd:{qid} ; wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks >= {bound})
  OPTIONAL {{
    ?article schema:about ?item ;
             schema:isPartOf <https://en.wikipedia.org/> ;
             schema:name ?enwiki .
  }}
  OPTIONAL {{ ?item rdfs:label ?itemLabel . FILTER(LANG(?itemLabel) = "en") }}
}}
LIMIT 60000""")


def strip_disambiguator(title: str) -> str:
    if title.endswith(")") and " (" in title:
        return title[: title.rindex(" (")]
    return title


def main() -> int:
    provider = WikidataProvider(user_agent=USER_AGENT,
                                timeout_seconds=120.0,
                                maximum_response_bytes=80_000_000)
    if "--counts" in sys.argv:
        for family, qid, bound in SLICES:
            print(f"{family:<11} {qid:<10} >= {bound:>2} sitelinks: "
                  f"{count(provider, qid, bound):>7}", file=sys.stderr)
        return 0

    names: dict[str, dict] = {}
    for family, qid, bound in SLICES:
        rows = fetch(provider, qid, bound)
        print(f"  {family}: {len(rows)} rows", file=sys.stderr)
        for row in rows:
            item_qid = row["item"]["value"].rsplit("/", 1)[-1]
            sitelinks = int(row["sitelinks"]["value"])
            labels = set()
            label = row.get("itemLabel", {}).get("value", "")
            if label and label != item_qid:
                labels.add(label)
            enwiki = row.get("enwiki", {}).get("value", "")
            if enwiki:
                labels.add(strip_disambiguator(enwiki))
            for name in labels:
                key = normalize_text(name)
                if not key or len(key) < 2:
                    continue
                entry = names.setdefault(key, {"families": set(), "max_sitelinks": 0})
                entry["families"].add(family)
                entry["max_sitelinks"] = max(entry["max_sitelinks"], sitelinks)

    payload = {
        "source": "wikidata", "license": "CC0-1.0",
        "slices": [{"family": f, "class": q, "minimum_sitelinks": b} for f, q, b in SLICES],
        "names": {k: {"families": sorted(v["families"]),
                      "max_sitelinks": v["max_sitelinks"]}
                  for k, v in sorted(names.items())},
    }
    json.dump(payload, sys.stdout)
    print(f"\n  {len(names)} distinct normalized names", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
