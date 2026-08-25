#!/usr/bin/env python3
"""Count the ungrounded inferences, and name what they concentrate on.

**Why this exists: 16 rows that no other check could reach.** The v18 corpus
carried 16 inferred `One Piece` mentions and all 16 were wrong — attached to
Hikaru Utada, Wu Bai, Yoga Lin, none with any One Piece connection. They passed
validation because an inferred mention carries no offsets *by design*
(`mention_extract_v2.py:250`: "checked for everything except its span"), so the
5.9% of mentions that are guesses are exactly the 5.9% the offset machinery
cannot touch. Acceptance measures well-formedness; these were well-formed and
false.

**The mechanism was the prompt's own worked example**, which demonstrated
inferring that exact franchise — and the rule forbidding example reuse
(`never_reuse_a_franchise_or_relation_object_that_appears_only_in_an_example`)
lost to the example 16 times in one corpus. A defect nobody counts is a defect
nobody sees: this is the counter, beside `score_categorisation.py` for the same
reason `fx_106` went back into that scorer's denominator.

Three sections, each answering one question:

* **Volume** — how much of the corpus is guessed rather than read. Baseline
  2026-08-24: 627 of 10,627 (5.9%). The lane is meant to work, so zero is as
  suspicious as a spike — it would mean inference was disabled, not governed.
* **Concentration** — which labels are inferred across many *distinct
  performers*. A real franchise inferred from its own soundtracks clusters on
  few performers; an anchor is reached for from everywhere. One Piece scored
  10 distinct performers in 16 inferences; Bach's 68 concentrated on classical
  performers actually playing Bach.
* **Example residue** — inferred labels matching the entities in the contract's
  own `aboutness_example`, read from the contract rather than hardcoded so the
  check follows the example wherever it moves. **This number is the tripwire:
  after the v19 invented-entity example, anything here can only have come from
  the prompt, because `Mistvale Chronicle` exists nowhere else.**

    python3 tools/score_inferences.py out/ris/verdicts_v19.json out/ris/items_v19.jsonl
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
CONTRACT = HERE / ".." / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"


def example_labels() -> set:
    """Every canonical/english label the aboutness example names, lowercased.

    Derived, never listed: a hardcoded copy of the example's entities is a
    second file that can disagree with the first, which is this session's
    thrice-paid defect (the schema staging line, the emitter's `ris_v15`
    guard, the fixtures shard).
    """
    contract = json.loads(CONTRACT.resolve().read_text(encoding="utf-8"))
    example = json.loads(contract["prompt"]["aboutness_example"])
    labels = set()
    for item in example.get("items", []):
        for mention in item.get("mentions", []):
            for field in ("canonical_label_hypothesis", "english_label",
                          "original_label", "surface"):
                value = (mention.get(field) or "").strip()
                if value:
                    labels.add(value.casefold())
            for relation in (mention.get("relation_hypotheses") or []):
                value = (relation.get("object_label_hypothesis") or "").strip()
                if value:
                    labels.add(value.casefold())
    return labels


def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    performers: dict[str, str] = {}
    if len(sys.argv) > 2:
        for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
            if line.strip():
                item = json.loads(line)
                performers[item["row_id"]] = (item.get("fields") or {}).get("performer", "")

    anchors = example_labels()
    total = inferred = 0
    #: label -> set of distinct performers it was inferred beside
    spread: dict[str, set] = collections.defaultdict(set)
    counts: collections.Counter = collections.Counter()
    residue: collections.Counter = collections.Counter()

    for verdict in verdicts["verdicts"]:
        performer = performers.get(verdict.get("row_id"), "")
        for mention in verdict.get("mentions", []):
            total += 1
            # **Grounded means it has a span.** `source_field == "inferred"` is
            # the declared form, but the property that matters to validation is
            # the offsets' absence, so that is what is tested.
            if mention.get("start") is not None:
                continue
            inferred += 1
            label = (mention.get("canonical_label_hypothesis")
                     or mention.get("surface") or "").strip()
            if not label:
                continue
            counts[label] += 1
            if performer:
                spread[label].add(performer)
            if label.casefold() in anchors:
                residue[label] += 1

    print(json.dumps({
        "mentions": total,
        "inferred": inferred,
        "inferred_share": round(inferred / total, 4) if total else None,
        # **The tripwire.** Non-zero means the model reproduced an entity from
        # its own worked example — with the v19 invented example, there is no
        # other place these labels exist.
        "example_residue": dict(residue),
    }, indent=1, ensure_ascii=False))

    print("\nmost-inferred labels (label, inferences, distinct performers):")
    for label, n in counts.most_common(15):
        width = len(spread.get(label, ()))
        # Many performers for one inferred label is the anchor signature: a
        # genuine franchise clusters on the artists actually attached to it.
        flag = "  <- wide spread" if width >= 5 and n >= 5 else ""
        print(f"  {n:4d}  x{width:<3} performers  {label[:48]}{flag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
