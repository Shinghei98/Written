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

Pass A — per-row corrections, both deterministic, both counted:

1. **An album term's name is the release title, whole and verbatim** (the
   owner's identity ruling). Where a mention's `source_field` is `album`,
   its canonical label is restored to the input's album string exactly.

2. **A work claiming two composers is a container, not a work** — a
   grammatical impossibility; dropped, its people surviving as their own
   mentions. Album-family terms exempt.

Pass B — the container taxonomy (GRAMMARBOOK §2.21, owner's replan
2026-08-26). The v20 grammar had one container word — `franchise` — and
the model filed groups, labels, platforms, work-cycles and even genres
under it. Typing is decided here, from member-family evidence aggregated
across the whole corpus, never by the model and never by name:

- person-majority members            -> group   (member_of_group; a work
                                       pointing into its group becomes
                                       performed_by — two facts, two
                                       predicates)
- any group member                   -> organization (signed_to_label);
                                       + work members -> franchise stays
- work-majority members              -> collection (work_in_collection;
                                       family album when album members
                                       exist, else work)
- label equals a source code seen in
  this corpus's own items            -> platform (platform_of) — the
                                       registry is the data, not a list
- object label in the classification
  vocabulary (optional 4th argument:
  one label per line, exported from
  the ontology's genre/era labels)   -> the relation becomes `broader`
                                       and the object entity is dropped:
                                       classifications are edges, never
                                       entities
- ambiguous membership               -> family `unknown`, counted, held

    python3 tools/ris_validate_corrections.py results.jsonl items.jsonl \\
        corrected.jsonl [classification_labels.txt]
"""
from __future__ import annotations

import json
import pathlib
import sys
from collections import defaultdict

WORK_FAMILIES = {"work", "music_work", "album", "music_recording"}


def _norm(label: str) -> str:
    return " ".join((label or "").strip().casefold().replace("-", " ").split())


def main() -> int:
    results_path = pathlib.Path(sys.argv[1])
    items_path = pathlib.Path(sys.argv[2])
    out_path = pathlib.Path(sys.argv[3])
    classification: set[str] = set()
    if len(sys.argv) > 4:
        classification = {
            _norm(line) for line in
            pathlib.Path(sys.argv[4]).read_text(encoding="utf-8").splitlines()
            if line.strip()}

    album_by_row: dict[str, str] = {}
    source_codes: set[str] = set()
    for line in items_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        album = ((item.get("fields") or {}).get("album") or "").strip()
        if album and item.get("row_id"):
            album_by_row[item["row_id"]] = album
        if item.get("source"):
            source_codes.add(_norm(item["source"]))

    # ------------------------------------------------------------------
    # First read: corpus-wide member evidence per container label.
    # ------------------------------------------------------------------
    members: dict[str, list[str]] = defaultdict(list)  # container -> member families
    rows_raw: list[str] = []
    for line in results_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows_raw.append(line)
        try:
            body = json.loads(json.loads(line).get("body") or "")
        except (ValueError, TypeError):
            continue
        for item in body.get("items", []):
            for m in item.get("mentions", []):
                fam = m.get("family_hypothesis") or ""
                for r in (m.get("relation_hypotheses") or []):
                    if r.get("predicate") != "part_of_franchise":
                        continue
                    obj = _norm(r.get("object_label_hypothesis") or "")
                    if obj:
                        members[obj].append(fam)

    verdicts: dict[str, str] = {}
    for container, fams in members.items():
        if container in source_codes:
            verdicts[container] = "platform"
            continue
        has_group = "group" in fams
        works = sum(1 for f in fams if f in WORK_FAMILIES)
        persons = sum(1 for f in fams if f == "person")
        if has_group and works:
            verdicts[container] = "franchise"
        elif has_group:
            verdicts[container] = "organization"
        elif persons > works and persons > 0:
            verdicts[container] = "group"
        elif works:
            verdicts[container] = "collection"
        else:
            verdicts[container] = "held"

    member_predicate = {
        "group": "member_of_group",
        "organization": "signed_to_label",
        "platform": "platform_of",
        "collection": "work_in_collection",
        "franchise": "part_of_franchise",
    }

    # ------------------------------------------------------------------
    # Second read: apply passes A and B.
    # ------------------------------------------------------------------
    restored = dropped = rows = 0
    retyped: dict[str, int] = defaultdict(int)
    relations_retyped = classification_edges = entities_dropped = held = 0
    out_lines = []
    for line in rows_raw:
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
                fam = m.get("family_hypothesis") or ""
                label = _norm(m.get("canonical_label_hypothesis") or "")

                # Pass A.2 — the impossible work.
                if fam not in ("album",):
                    composers = {
                        (r.get("object_label_hypothesis") or "").strip().casefold()
                        for r in (m.get("relation_hypotheses") or [])
                        if r.get("predicate") == "composed_by"}
                    composers.discard("")
                    if len(composers) > 1:
                        dropped += 1
                        changed = True
                        continue

                # Pass B — a classification minted as an entity is dropped;
                # the relations that pointed at it become `broader` on
                # their subjects (rewritten below when met).
                if fam == "franchise" and label in classification:
                    entities_dropped += 1
                    changed = True
                    continue

                # Pass B — container retype by corpus verdict.
                if fam == "franchise" and label in verdicts:
                    verdict = verdicts[label]
                    if verdict == "held":
                        m["family_hypothesis"] = "unknown"
                        held += 1
                        changed = True
                    elif verdict == "collection":
                        member_fams = members[label]
                        m["family_hypothesis"] = (
                            "album" if "album" in member_fams else "work")
                        retyped[verdict] += 1
                        changed = True
                    elif verdict != "franchise":
                        m["family_hypothesis"] = verdict
                        retyped[verdict] += 1
                        changed = True

                # Pass B — relation predicates follow the container's type.
                for r in (m.get("relation_hypotheses") or []):
                    if r.get("predicate") != "part_of_franchise":
                        continue
                    obj = _norm(r.get("object_label_hypothesis") or "")
                    if obj in classification:
                        r["predicate"] = "broader"
                        classification_edges += 1
                        changed = True
                        continue
                    verdict = verdicts.get(obj)
                    if verdict in (None, "held", "franchise"):
                        continue
                    if verdict == "group" and fam in WORK_FAMILIES:
                        # A work pointing into its group is the group
                        # performing it.
                        r["predicate"] = "performed_by"
                    else:
                        r["predicate"] = member_predicate[verdict]
                    relations_retyped += 1
                    changed = True

                # Pass A.1 — the album name, whole.
                if (album and m.get("source_field") == "album"
                        and (m.get("canonical_label_hypothesis") or "") != album):
                    m["canonical_label_hypothesis"] = album
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
                      "containers_retyped": dict(retyped),
                      "relations_retyped": relations_retyped,
                      "classification_edges": classification_edges,
                      "classification_entities_dropped": entities_dropped,
                      "containers_held": held,
                      "out": str(out_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
