#!/usr/bin/env python3
"""Turn the subtype pass's answers into a migration, counted out loud.

An empty answer writes nothing: null **is** the held-pending state (0342), and
a stored `none` would be indistinguishable from a person the pass never
reached. Since 0477 an answer is a ranked list with confidences and each
becomes a `person_category_support` row; `person_subtype` is the heaviest,
kept by trigger. The category list is restated in 0477's check constraint;
an answer off the list dies there loudly rather than being filtered here
silently, so the two copies cannot drift without a failed apply saying so.

    python3 tools/ris_emit_person_subtypes.py answers.jsonl <n>
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = REPOSITORY / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def main() -> int:
    answers = [json.loads(line) for line
               in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
               if line.strip()]
    number = sys.argv[2]
    import os
    prompt = os.environ.get("WRITTEN_CORPUS_PROMPT") or json.loads(
        CONTRACT.read_text())["versions"]["prompt"]
    corpus = "ris_" + prompt.rsplit("_", 1)[-1]

    counts: collections.Counter = collections.Counter()
    rows = []          # (normalized label, category, confidence, rank)
    persons = held = 0
    for answer in answers:
        persons += 1
        categories = answer.get("categories")
        if categories is None and answer.get("subtype"):
            categories = [{"category": answer["subtype"],
                           "confidence": answer.get("confidence") or 1.0}]
        categories = [c for c in (categories or []) if c.get("category")]
        if not categories:
            held += 1
            counts["none"] += 1
            continue
        key = answer["key"].rsplit("|", 1)[0]
        for rank, c in enumerate(categories[:3]):
            counts[c["category"]] += 1
            rows.append((key, c["category"], float(c.get("confidence") or 0), rank))

    header = (
        f"-- {number} — the corpus's persons take their kinds ({corpus}).\n"
        "--\n"
        f"-- {persons} persons asked; {persons - held} answered with one or more of the\n"
        f"-- owner's nine categories (2026-09-08), {held} answered none and stay held —\n"
        "-- unminted, not refused, per 0342. A person may hold several categories;\n"
        "-- each answer is a support row and `person_subtype` is the heaviest, kept\n"
        f"-- by trigger (0477). Distribution of answers: {dict(counts.most_common())}.\n"
        "--\n"
        "-- Rows key on (normalized_label, family='person'); a person this corpus\n"
        "-- named that the dictionary does not hold writes nothing, and the count\n"
        "-- below says how many landed rather than leaving the difference silent.\n"
        "\n"
        "do $$\n"
        "declare\n"
        "  n integer := 0;\n"
        "  touched integer;\n"
        "begin")
    out = [header]
    for key, category, confidence, rank in sorted(rows):
        out.append(
            "  insert into semantic_private.person_category_support\n"
            "    (term_id, category, support, source)\n"
            f"  select t.id, {quote(category)}, {confidence:.3f}, 'model_pass'\n"
            "    from semantic_private.presumed_terms t\n"
            f"   where t.normalized_label = {quote(key)} and t.family = 'person'\n"
            "  on conflict (term_id, category) do update\n"
            "    set support = greatest(person_category_support.support, excluded.support);\n"
            "  get diagnostics touched = row_count; n := n + touched;")
    out.append(
        f"  raise notice '{number}: % of {len(rows)} category answers landed', n;\n"
        f"  if {len(rows)} > 0 and n = 0 then\n"
        "    raise exception\n"
        f"      '{number}: answers were emitted and none matched a dictionary row';\n"
        "  end if;\n"
        "end;\n"
        "$$;\n")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_persons_take_their_kinds.sql")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(json.dumps({"persons": persons, "answers": len(rows), "held_none": held,
                      "distribution": dict(counts.most_common()),
                      "corpus": corpus, "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
