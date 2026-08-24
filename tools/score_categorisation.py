#!/usr/bin/env python3
"""Score an extraction against the typed evaluation corpus.

**The categorisation was an opinion and this makes it a number.** `v1`'s
expectations are prose — *"a work and a performing group"* — which a person can
read and a run cannot be scored against, so every judgement about whether the
extractor got better was somebody's reading of twenty rows. `v2` names the
families a correct answer must contain, must not contain, and how many mentions
bound it.

    python3 tools/score_categorisation.py out/ris/verdicts.json
    python3 tools/score_categorisation.py out/ris/verdicts.json --corpus v2

The verdicts file is the extractor's own output — `{"verdicts": [{"row_id",
"mentions": [...]}]}` — and items are matched to corpus cases by `row_id`
carrying the case id, which is how `ris_corpus_probe.py` submits them.

**A case that is not in the answer is not scored as wrong**, it is reported as
absent. A missing run and a run that failed every case are different facts, and
a scorer that folds them together will report progress the first time the file
path is mistyped.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = REPOSITORY / "semantic" / "fixtures" / "mention_extract"


def load_corpus(version: str) -> dict:
    path = FIXTURES / f"evaluation_corpus_{version}.json"
    corpus = json.loads(path.read_text(encoding="utf-8"))
    if not corpus.get("items"):
        raise SystemExit(f"{path} holds no items")
    return corpus


def families_of(mentions) -> list[str]:
    return [m.get("family_hypothesis") for m in mentions
            if m.get("family_hypothesis")]


def score_case(case: dict, mentions: list) -> dict:
    """One case, judged on what its `expect` block actually states.

    Each clause is scored separately and reported separately. A single
    pass/fail per case hides which half of a rule broke — and the two halves
    fail for different reasons: `families` misses when the model does not see
    an entity, `forbid_families` misses when it sees one and types it wrongly.
    """
    expect = case.get("expect") or {}
    got = families_of(mentions)
    seen = set(got)

    required = list(expect.get("families") or [])
    missing = [family for family in required if family not in seen]

    forbidden = list(expect.get("forbid_families") or [])
    intruding = [family for family in forbidden if family in seen]

    bounds: list[str] = []
    if "at_least" in expect and len(mentions) < expect["at_least"]:
        bounds.append(f"{len(mentions)} mentions, wanted at least {expect['at_least']}")
    if "at_most" in expect and len(mentions) > expect["at_most"]:
        bounds.append(f"{len(mentions)} mentions, wanted at most {expect['at_most']}")

    return {
        "id": case["id"],
        "lesson": case.get("lesson", ""),
        "families_seen": got,
        "missing_required": missing,
        "forbidden_present": intruding,
        "bound_failures": bounds,
        "passed": not (missing or intruding or bounds),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("verdicts", type=pathlib.Path)
    parser.add_argument("--corpus", default="v2")
    parser.add_argument("--quiet", action="store_true",
                        help="report only the cases that failed")
    arguments = parser.parse_args()

    corpus = load_corpus(arguments.corpus)
    answers = json.loads(arguments.verdicts.read_text(encoding="utf-8"))
    by_id = {}
    for verdict in answers.get("verdicts", []):
        by_id.setdefault(str(verdict.get("row_id")), verdict.get("mentions") or [])

    results, absent = [], []
    for case in corpus["items"]:
        if case["id"] in by_id:
            results.append(score_case(case, by_id[case["id"]]))
        else:
            absent.append(case["id"])

    for result in results:
        if arguments.quiet and result["passed"]:
            continue
        mark = "pass" if result["passed"] else "FAIL"
        print(f"\n{mark}  {result['id']}  {result['lesson']}")
        print(f"      families seen: {result['families_seen'] or '(none)'}")
        for label, values in (("missing", result["missing_required"]),
                              ("forbidden present", result["forbidden_present"])):
            if values:
                print(f"      {label}: {', '.join(values)}")
        for failure in result["bound_failures"]:
            print(f"      bound: {failure}")

    passed = sum(1 for r in results if r["passed"])
    print("\n" + json.dumps({
        "corpus": corpus["corpus_version"],
        "scored": len(results),
        "passed": passed,
        # **Absent is its own number.** Zero scored and zero passed would
        # otherwise read as a total failure rather than as a run that never
        # reached the corpus.
        "absent_from_answer": absent,
    }, ensure_ascii=False))
    return 0 if results and passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
