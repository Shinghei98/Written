#!/usr/bin/env python3
"""Build the extraction work list from the full distillation, for a lab GPU.

**The complete distillation, unredacted.** `public.distilled_records` is what
the device sent — `name`, `creator`, `detail`, `extra` — and it is plaintext
at rest (`0001_initial.sql:43-70`), so it needs no vault key. It is also more
complete than the promoted projection, which strips calendar titles and
excludes YouTube titles by design. The owner authorised using it whole, for
testing on RIS; the AWS lane is untouched and still reads the vault through
KMS with the lineage guarantees that come with it.

**This file holds the credentials and the GPU does not.** It runs where the
database is already reachable, writes JSONL, and that JSONL is all that
crosses to the cluster. A shared machine never sees a connection string.

    python3 tools/ris_build_items.py out/items.jsonl [--limit N]
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: Which source profile the contract knows for each distilled source. The
#: request schema's enum is closed, so a source with no profile is not sent
#: rather than being described by somebody else's rules.
SOURCE_PROFILE = {
    "youtube": "youtube",
    "apple_music": "apple_music",
    "music_library": "apple_music",
    "spotify": "spotify",
    "apple_calendar": "calendar",
    "google_calendar": "calendar",
    "outlook_calendar": "calendar",
    "podcast": "podcast",
}

#: Sources that carry no extractable text. `health` is quantities and
#: `user` is what somebody typed about themselves; neither is a title, and
#: sending them would be asking a language model to read a number.
NO_TEXT = {"health", "user"}


def query(sql: str) -> list[dict]:
    """Read through the linked Supabase project."""
    result = subprocess.run(
        ["supabase", "db", "query", "--linked", sql],
        capture_output=True, text=True, cwd=REPOSITORY)
    if result.returncode != 0:
        raise SystemExit(f"query failed: {result.stderr[:400]}")
    text = result.stdout
    return json.loads(text[text.find("{"):])["rows"]


def fields_for(row: dict) -> dict:
    """The source fields the request schema admits, and nothing else.

    Absent keys are omitted rather than sent empty: `minProperties` is
    satisfied by the title, and the schema refuses nothing it never saw.
    """
    fields: dict = {}
    if row.get("name"):
        fields["title"] = str(row["name"])[:256]
    if row.get("creator"):
        # A channel for YouTube, a performer for music: the same column
        # carries both, and the profile tells the model which it is reading.
        if row.get("source") == "youtube":
            fields["channel_label"] = str(row["creator"])[:128]
        else:
            fields["performer"] = str(row["creator"])[:256]
    detail = row.get("detail")
    if detail and row.get("source") != "youtube":
        fields["album"] = str(detail)[:256]
    return fields


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    limit = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    # **Read through the summary view, never the table.** `distilled_records`
    # is append-only and stores only changes, so the raw table holds every
    # historical version of a row; the view returns the latest per item. It
    # also has no surrogate key — identity is (user, source, data_type,
    # item_id) — which is what `row_id` is built from below.
    sources = ", ".join(f"'{s}'" for s in SOURCE_PROFILE)
    rows = query(f"""
        select d.user_id::text as user_id,
               d.source, d.data_type, d.name, d.creator, d.detail,
               d.item_id
          from public.summary_distilled_records d
         where d.source in ({sources})
           and coalesce(d.name, '') <> ''
           and d.removed_at is null
           and coalesce(d.extra ->> 'markedRemoved', '') <> '1'
         order by d.source, d.item_id
         {f'limit {limit}' if limit else ''}
    """)

    # The parents the model may echo, exactly as the worker supplies them:
    # ids and labels only, axes excluded, most load-bearing first.
    parents = query("""
        select c.concept_key as term_id, cr.preferred_label as label
          from ontology.concept_edges e
          join ontology.concepts c on c.id = e.object_concept_id
          join ontology.concept_revisions cr
            on cr.concept_id = e.object_concept_id
           and cr.ontology_version_id = e.ontology_version_id
         where e.predicate_key = 'broader' and e.status = 'active'
           and e.ontology_version_id =
               (select id from ontology.versions where status = 'published')
           and c.concept_key !~ '^(era|sphere|scene):'
         group by c.concept_key, cr.preferred_label
         order by count(distinct e.subject_concept_id) desc, c.concept_key
         limit 40
    """)
    candidates = [{"term_id": p["term_id"][:128], "label": p["label"][:128]}
                  for p in parents]

    written, skipped = 0, 0
    by_source: dict[str, int] = {}
    with out_path.open("w") as out:
        for row in rows:
            source = row["source"]
            if source in NO_TEXT:
                skipped += 1
                continue
            fields = fields_for(row)
            if not fields:
                skipped += 1
                continue
            # Identity without a surrogate key: the four columns that
            # uniquely name an item, hashed so it fits the request schema's
            # 64-character opaque id and carries nothing about whose it is.
            row_id = hashlib.sha256(
                "|".join([row["user_id"], source, str(row.get("data_type")),
                          str(row.get("item_id"))]).encode()).hexdigest()[:40]
            out.write(json.dumps({
                "row_id": row_id,
                "user_id": row["user_id"],
                "source_code": source,
                "data_type": row.get("data_type"),
                "item_id": row.get("item_id"),
                "source_profile": SOURCE_PROFILE[source],
                "source_action": row.get("data_type"),
                "fields": fields,
                "parent_candidates": candidates,
            }, ensure_ascii=False) + "\n")
            written += 1
            by_source[source] = by_source.get(source, 0) + 1

    # **Per source, against what the database holds.** A source that quietly
    # contributed nothing is the failure this count exists to make visible.
    print(json.dumps({"written": written, "skipped": skipped,
                      "by_source": by_source, "out": str(out_path)},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
