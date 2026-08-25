#!/usr/bin/env python3
"""Deterministic corrections over extraction results — structure over prompt.

**The principle this file exists for (owner, 2026-08-25): a rule about a
representation that another rule manufactures cannot live in the prompt.**
Prompt rules are declarative over the surfaces the model reads; its own
transformations then create surfaces no rule ever re-checked. Measured on
the v20 run's first half: the strip-the-credits rule manufactured the bare
container "Violin Concertos" out of "Brahms & Ligeti: Violin Concertos"
*after* the container rule's checkpoint had passed. Ordering cannot be
prompted; it can be validated.

Two corrections, both deterministic, both counted, neither naming a term:

1. **An album term's name is the release title, whole and verbatim** (the
   owner's identity ruling). Where a mention's `source_field` is `album`,
   its canonical label is restored to the input's album string exactly —
   stripping is for commentary *around* a title, never for parts *of* one.
   Repairs both the manufactured container and the beheaded Kiroro title,
   retroactively, with no re-extraction.

2. **A work claiming two composers is a container, not a work.** One work
   cannot be `composed_by` two people who never collaborated — a
   grammatical impossibility, not a vocabulary judgment. The mention is
   dropped (its composers and performers already stand as their own
   mentions); album-family terms are exempt, a two-composer *release*
   being a perfectly real thing to own.

    python3 tools/ris_validate_corrections.py results.jsonl items.jsonl \\
        corrected.jsonl
"""
from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    results_path = pathlib.Path(sys.argv[1])
    items_path = pathlib.Path(sys.argv[2])
    out_path = pathlib.Path(sys.argv[3])

    album_by_row: dict[str, str] = {}
    for line in items_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        album = ((item.get("fields") or {}).get("album") or "").strip()
        if album and item.get("row_id"):
            album_by_row[item["row_id"]] = album

    restored = dropped = rows = 0
    out_lines = []
    for line in results_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        rows += 1
        try:
            body = json.loads(row.get("body") or "")
        except (ValueError, TypeError):
            out_lines.append(line)
            continue
        album = album_by_row.get(row.get("row_id") or "")
        changed = False
        for item in body.get("items", []):
            kept = []
            for m in item.get("mentions", []):
                # 2. The impossible work: two distinct composers.
                if m.get("family_hypothesis") not in ("album",):
                    composers = {
                        (r.get("object_label_hypothesis") or "").strip().casefold()
                        for r in (m.get("relation_hypotheses") or [])
                        if r.get("predicate") == "composed_by"}
                    composers.discard("")
                    if len(composers) > 1:
                        dropped += 1
                        changed = True
                        continue
                # 1. The album name, whole.
                if (album and m.get("source_field") == "album"
                        and (m.get("canonical_label_hypothesis") or "") != album):
                    m["canonical_label_hypothesis"] = album
                    # The halves recompute downstream from the whole name;
                    # a beheaded english/original must not survive beside a
                    # restored canonical.
                    if (m.get("english_label")
                            and m["english_label"] not in (album,)):
                        m["english_label"] = album
                    restored += 1
                    changed = True
                kept.append(m)
            item["mentions"] = kept
        if changed:
            row["body"] = json.dumps(body, ensure_ascii=False)
            out_lines.append(json.dumps(row, ensure_ascii=False))
        else:
            out_lines.append(line)

    out_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    print(json.dumps({"rows": rows, "album_names_restored": restored,
                      "impossible_works_dropped": dropped,
                      "out": str(out_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
