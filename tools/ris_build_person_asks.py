#!/usr/bin/env python3
"""Every person the dictionary holds without a category, with what is known.

The category pass (`ris_person_subtype.py`) asks one narrow question per
person; this builds its ask list from the dictionary rather than from one
corpus's mentions, so a person seen in three corpora and categorised in none
is asked once. Context is what the pass has always been given: the titles
the person was seen in (from a verdicts file) and the relations the
dictionary states about them.

    WRITTEN_DATABASE_URL=... python3 tools/ris_build_person_asks.py \\
        out/ris/persons.jsonl out/ris/verdicts_v24.json out/ris/items_v22.jsonl
"""
from __future__ import annotations

import collections
import json
import os
import pathlib
import sys

MAX_TITLES = 6
MAX_RELATED = 6


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    verdicts = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    items = {}
    for line in pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines():
        if line.strip():
            it = json.loads(line)
            items[it["row_id"]] = " | ".join(str(v) for v in it.get("fields", {}).values())
    titles: dict[str, list[str]] = collections.defaultdict(list)
    for vd in verdicts.get("verdicts", []):
        title = items.get(vd["row_id"])
        if not title:
            continue
        for m in vd.get("mentions", []):
            if m.get("family_hypothesis") == "person":
                key = (m.get("canonical_label_hypothesis") or "").strip().casefold()
                if key and title not in titles[key] and len(titles[key]) < MAX_TITLES:
                    titles[key].append(title[:120])

    import psycopg
    with psycopg.connect(os.environ["WRITTEN_DATABASE_URL"]) as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                select t.id, t.normalized_label, t.canonical_label, t.english_label,
                       coalesce(t.mention_support, 0) + coalesce(t.entry_support, 0),
                       t.promoted_concept_id is not null
                  from semantic_private.presumed_terms t
                 where t.family = 'person' and t.person_subtype is null
                 order by 5 desc, t.normalized_label""")
            persons = cursor.fetchall()
            cursor.execute("""
                select s.normalized_label, r.predicate, o.canonical_label
                  from semantic_private.presumed_term_relations r
                  join semantic_private.presumed_terms s on s.id = r.subject_term_id
                  join semantic_private.presumed_terms o on o.id = r.object_term_id
                 where s.family = 'person' and s.person_subtype is null""")
            related: dict[str, list[str]] = collections.defaultdict(list)
            for label, predicate, obj in cursor.fetchall():
                if len(related[label]) < MAX_RELATED:
                    related[label].append(f"{predicate} {obj}")

    written = 0
    with out.open("w", encoding="utf-8") as handle:
        for _id, norm, canonical, english, seen, grounded in persons:
            handle.write(json.dumps({
                "key": f"{norm}|person",
                "label": english or canonical,
                "family": "person",
                "seen": int(seen),
                "grounded": bool(grounded),
                "context_titles": titles.get(norm) or titles.get((english or canonical).casefold()) or [],
                "related": related.get(norm, []),
            }, ensure_ascii=False) + "\n")
            written += 1
    print(json.dumps({"persons": written, "out": str(out)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
