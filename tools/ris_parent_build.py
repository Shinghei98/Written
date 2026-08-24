#!/usr/bin/env python3
"""Select the mentions that came back with no parent, and ask about those only.

**Measured on David's v17 run: 374 of 4,003 mentions carried a parent — 9.3% —
and zero missing-parent proposals were made in 1,540 items.** The candidate list
is not the problem: `creator -> genre` is the dominant edge in the published
tree (2,441 of them), so Bach under Classical is exactly what this ontology
does. The model simply answered inconsistently — Chopin took `Classical`, Bach
took nothing, on the same list in the same run.

**That is `ris_relabel`'s finding again.** In extraction, `parent_candidate_id`
is one of eighteen fields decided in a single forward pass with thinking
disabled and a large grammar constraining every token. The native-label rule was
stated three ways in v14 and moved nothing; what moved it was asking one
question with room to think. This selects the rows for that question.

**One row per (term, family), not per mention.** The parent of a term does not
depend on which title it was seen in, and 4,003 mentions collapse to far fewer
distinct terms — so the pass is smaller and an answer applies everywhere the
term appears. The context title still travels, because it is what separates
Sakura the idol from sakura the blossom.

    python3 tools/ris_parent_build.py verdicts.json items.jsonl parents.jsonl
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys
import unicodedata


def key(text: str) -> str:
    """The identity two spellings of one term share."""
    return unicodedata.normalize("NFKC", (text or "").strip()).casefold()


def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    items_path = pathlib.Path(sys.argv[2])
    out = pathlib.Path(sys.argv[3])

    # The titles, and the candidate list the run was actually given. Reading
    # the candidates from the items file rather than the database keeps this
    # pass asking about the same forty the extraction was offered — a different
    # list would make the comparison meaningless.
    titles: dict[str, str] = {}
    candidates: list[dict] = []
    with items_path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            item = json.loads(line)
            titles[item["row_id"]] = item.get("fields", {}).get("title", "")
            if not candidates:
                candidates = item.get("parent_candidates", [])

    picked: dict[tuple[str, str], dict] = {}
    already = 0
    for verdict in verdicts["verdicts"]:
        title = titles.get(verdict.get("row_id"), "")
        for mention in verdict.get("mentions", []):
            if mention.get("parent_candidate_id"):
                already += 1
                continue
            label = (mention.get("canonical_label_hypothesis")
                     or mention.get("surface") or "").strip()
            family = mention.get("family_hypothesis") or "unknown"
            if not label:
                continue
            k = (key(label), family)
            if k in picked:
                picked[k]["seen"] += 1
                continue
            picked[k] = {
                "key": f"{k[0]}|{family}",
                "label": label,
                "surface": mention.get("surface"),
                "family": family,
                "cardinal": mention.get("selected_cardinal"),
                "context_title": title,
                "seen": 1,
            }

    out.write_text(
        "\n".join(json.dumps(p, ensure_ascii=False) for p in picked.values()) + "\n",
        encoding="utf-8")

    families = collections.Counter(p["family"] for p in picked.values())
    print(json.dumps({
        "unparented_mentions": sum(p["seen"] for p in picked.values()),
        "already_parented": already,
        "distinct_terms_to_ask": len(picked),
        "candidates_offered": len(candidates),
        "by_family": dict(families.most_common()),
        "out": str(out),
    }, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
