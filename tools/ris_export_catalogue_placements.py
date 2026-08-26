#!/usr/bin/env python3
"""Export the catalogue's placements for the ladder's tier-2 join.

Writes `{label_key: [parent_concept_key, ...]}` for every active label at
the published ontology version, where the parents are the label's
concept's active `broader` objects. `ris_parent_merge.py` takes the file
as its optional fifth argument: a linked term then binds against what the
catalogue already knows, not only what this round placed — tier 2 of the
disambiguation ladder (GRAMMARBOOK §2.18), built 2026-08-26.

Label keys use the merge tool's own normalization (NFKC + casefold), so
the two sides of the join cannot drift.

    WRITTEN_DATABASE_URL=... python3 tools/ris_export_catalogue_placements.py \\
        out/catalogue_placements.json
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import unicodedata

QUERY = """
select l.label, pk.concept_key as parent_key
  from ontology.concept_labels l
  join ontology.versions v on v.id = l.ontology_version_id
   and v.status = 'published'
  join ontology.concept_edges e
    on e.subject_concept_id = l.concept_id
   and e.ontology_version_id = v.id
   and e.predicate_key = 'broader' and e.status = 'active'
  join ontology.concepts pk on pk.id = e.object_concept_id
 where l.status = 'active'
"""


def key(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "").strip()).casefold()


def main() -> int:
    database_url = os.environ.get("WRITTEN_DATABASE_URL")
    if not database_url:
        print("WRITTEN_DATABASE_URL is not set", file=sys.stderr)
        return 2
    out_path = pathlib.Path(sys.argv[1])

    import psycopg

    placements: dict[str, set] = {}
    with psycopg.connect(database_url, prepare_threshold=None) as connection:
        with connection.cursor() as cursor:
            cursor.execute(QUERY)
            for label, parent_key in cursor.fetchall():
                placements.setdefault(key(label), set()).add(parent_key)

    out_path.write_text(json.dumps(
        {k: sorted(v) for k, v in placements.items()},
        ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"labels": len(placements), "out": str(out_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
