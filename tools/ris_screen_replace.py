#!/usr/bin/env python3
"""Re-ask screen works' genres against Wikidata — the re-placement pass.

**Why (owner, 2026-08-26).** The dictionary bridge (0369/0386) promoted
the model's guessed `broader` genres wholesale, before the screen-genre
table (0389) existed. This pass re-asks every work carrying a
bridge-stated screen genre against the same authority the table was
built from, so a guess is superseded by a read: Lucifer's model-guessed
horror becomes Wikidata's police procedural.

Determinism and refusals:
- A title is searched on Wikidata and candidates are kept only if their
  `P31` (instance of) is a screen class (film / TV series / anime forms).
- **Exactly one candidate binds. Two refuse** — the ladder's rule; a
  refused or absent title keeps its standing edges (no information is
  not a reason to destroy a guess).
- `P136` genre QIDs are intersected with OUR vocabulary's own Wikidata
  ids (`concept_labels.external_ref`), so the mapping is id-to-id —
  no genre is ever matched by name.

Output: a JSON file of assignments consumed by the 0401 migration:
  [{"concept_key", "title", "qid", "genres": ["genre:..."]}, ...]

    WRITTEN_DATABASE_URL=... python3 tools/ris_screen_replace.py \\
        out/screen_replacements.json
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time
import urllib.parse
import urllib.request

SCREEN_CLASSES = {
    "Q11424",      # film
    "Q5398426",    # television series
    "Q1259759",    # miniseries
    "Q506240",     # television film
    "Q202866",     # animated film
    "Q117467246",  # animated television series
    "Q63952888",   # anime television series
    "Q11086742",   # anime film
    "Q220898",     # original video animation
    "Q5273965",    # web series
}

AFFECTED = """
select distinct c.id as concept_id, c.concept_key, r.preferred_label,
       -- The dictionary's english half: a kept concept can wear its
       -- original-script surface (洛基) while the english name lives in
       -- presumed_terms — searching Wikidata in english needs it.
       (select pt.english_label from semantic_private.presumed_terms pt
         where pt.promoted_concept_id = c.id and pt.english_label is not null
         order by pt.mention_support desc nulls last limit 1) as english_label
from ontology.concept_edges e
join ontology.versions v on v.id = e.ontology_version_id and v.status = 'published'
join ontology.concepts c on c.id = e.subject_concept_id
join ontology.concepts g on g.id = e.object_concept_id
join ontology.concept_revisions r on r.concept_id = c.id
  and r.ontology_version_id = v.id and r.status = 'active'
where e.status = 'active' and e.predicate_key = 'broader'
  and ((g.concept_key ~ '^genre:.*(film|procedural|thriller|fiction|television|drama$)'
        and e.provenance ->> 'source' ~ 'dictionary_bridge')
       -- A work whose only placement is the video-hub floor is a screen
       -- work whose genre question was never put to the authority —
       -- Loki's case (owner, 2026-08-26). Same re-ask, wider door.
       or (g.concept_key = 'hub:film_video'
           and not exists (
             select 1 from ontology.concept_edges ge
               join ontology.concepts gg on gg.id = ge.object_concept_id
              where ge.subject_concept_id = c.id
                and ge.ontology_version_id = v.id
                and ge.status = 'active' and ge.predicate_key = 'broader'
                and gg.concept_key like 'genre:%')))
"""

GENRE_QIDS = """
select distinct l.external_ref ->> 'external_id' as qid, c.concept_key
from ontology.concept_labels l
join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
join ontology.concepts c on c.id = l.concept_id
where l.status = 'active' and c.concept_key like 'genre:%'
  and l.external_ref ->> 'provider' = 'wikidata'
"""


def _api(params: dict) -> dict:
    """One call, patient: Wikidata answers 429 to eager clients, and the
    first run of this tool died on exactly that. Exponential backoff up
    to five tries; the caller still catches whatever survives them."""
    url = ("https://www.wikidata.org/w/api.php?format=json&"
           + urllib.parse.urlencode(params))
    request = urllib.request.Request(url, headers={
        "User-Agent": "written-screen-replace/1.0 (research; contact: owner)"})
    delay = 2.0
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 4:
                raise
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("unreachable")


def main() -> int:
    database_url = os.environ.get("WRITTEN_DATABASE_URL")
    if not database_url:
        print("WRITTEN_DATABASE_URL is not set", file=sys.stderr)
        return 2
    out_path = pathlib.Path(sys.argv[1])

    import psycopg
    with psycopg.connect(database_url, prepare_threshold=None) as connection:
        with connection.cursor() as cursor:
            cursor.execute(AFFECTED)
            works = cursor.fetchall()
            cursor.execute(GENRE_QIDS)
            genre_by_qid = {qid: key for qid, key in cursor.fetchall() if qid}

    assignments, refused, absent = [], [], []
    for _cid, concept_key, title, english in works:
        # Every name the concept answers to, most-english-first; a
        # non-ASCII name is also searched in its own script's language.
        searches = []
        for name in dict.fromkeys([english, title]):
            if not name:
                continue
            searches.append(("en", name))
            if any(ord(ch) > 127 for ch in name):
                lang = ("zh" if any('\u4e00' <= ch <= '\u9fff' for ch in name)
                        else "ja" if any('\u3040' <= ch <= '\u30ff' for ch in name)
                        else "ko")
                searches.append((lang, name))
        candidates = []
        for lang, name in searches:
            time.sleep(1.0)
            try:
                found = _api({"action": "wbsearchentities", "language": lang,
                              "type": "item", "limit": 8, "search": name})
            except Exception as error:  # noqa: BLE001 - recorded, not fatal
                absent.append({"concept_key": concept_key, "title": title,
                               "reason": f"search_error:{error}"})
                candidates = None
                break
            candidates = [hit["id"] for hit in found.get("search", [])
                          if (hit.get("label") or "").casefold() == name.casefold()
                          or (hit.get("match", {}).get("text") or "").casefold()
                          == name.casefold()]
            if candidates:
                break
        if candidates is None:
            continue
        if not candidates:
            absent.append({"concept_key": concept_key, "title": title,
                           "reason": "no_exact_label"})
            continue
        time.sleep(1.0)
        try:
            entities = _api({"action": "wbgetentities", "props": "claims",
                             "ids": "|".join(candidates[:8])})
        except Exception as error:  # noqa: BLE001 - recorded, not fatal
            absent.append({"concept_key": concept_key, "title": title,
                           "reason": f"entities_error:{error}"})
            continue
        screen_hits = []
        for qid, entity in (entities.get("entities") or {}).items():
            claims = entity.get("claims", {})
            p31 = {(c.get("mainsnak", {}).get("datavalue", {})
                    .get("value", {}) or {}).get("id")
                   for c in claims.get("P31", [])}
            if p31 & SCREEN_CLASSES:
                p136 = [(c.get("mainsnak", {}).get("datavalue", {})
                         .get("value", {}) or {}).get("id")
                        for c in claims.get("P136", [])]
                screen_hits.append((qid, [g for g in p136 if g]))
        if len(screen_hits) != 1:
            refused.append({"concept_key": concept_key, "title": title,
                            "candidates": len(screen_hits)})
            continue
        qid, genre_qids = screen_hits[0]
        ours = sorted({genre_by_qid[g] for g in genre_qids
                       if g in genre_by_qid})
        if ours:
            assignments.append({"concept_key": concept_key, "title": title,
                                "qid": qid, "genres": ours})
        else:
            absent.append({"concept_key": concept_key, "title": title,
                           "reason": "no_genre_in_vocabulary", "qid": qid})

    out_path.write_text(json.dumps({
        "assignments": assignments, "refused_ambiguous": refused,
        "absent": absent}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({"works": len(works), "assigned": len(assignments),
                      "refused": len(refused), "absent": len(absent),
                      "out": str(out_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
