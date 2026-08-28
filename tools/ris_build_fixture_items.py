#!/usr/bin/env python3
"""Build the fixtures shard, on the same item shape as production.

**Why this exists as a file rather than as a step in a runbook.**
`docs/RIS-DEPLOYMENT.md` §4 described this as "build items from
`evaluation_corpus_v2.json` with `row_id` = case id, on the same item shape as
production" and nothing implemented it, so the shard was hand-built once and
then sat still: a v16 fixtures shard was staged against a v18 prompt, which
scores the wrong prompt and reports a number for it. A step that has to be
remembered is a step that goes stale between runs.

**The production corpus cannot be scored against the fixtures**, which is what
makes this shard the only route to an accuracy number.
`tools/score_categorisation.py` matches items to cases by `row_id` carrying the
case id; production rows carry content hashes, so every case reports
`absent_from_answer`. That is the scorer being right — *"a missing run and a run
that failed every case are different facts."*

**`parent_candidates` is read from the production items file, never rebuilt
here.** §5.2's parent inventory is the top-40 `broader` parents as they stand
today; deriving it a second time would be a second implementation of the same
query, and the copy that drifts is always the one nobody is looking at. Passing
the production file also means the fixtures shard cannot describe a different
ontology from the run it is being compared against.

**Real titles never become fixtures.** The corpus is invented — migrations
`0239`/`0240` refuse an evaluation invocation naming a user, an observation or
retained source text. This reads that file and adds nothing of anybody's.

    python3 tools/ris_build_fixture_items.py out/ris/items_fixtures_v18.jsonl \\
        [--items out/ris/items_v18.jsonl] [--corpus semantic/fixtures/.../evaluation_corpus_v2.json]
"""
from __future__ import annotations

import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

CORPUS = (REPOSITORY / "semantic" / "fixtures" / "mention_extract"
          / "evaluation_corpus_v2.json")

#: The synthetic account these rows claim. **Not a real uuid and deliberately
#: not a valid one** — it ends in `fixt`, so a row that ever reached a real
#: table would fail its `uuid` cast rather than landing under somebody.
FIXTURE_USER = "00000000-0000-4000-8000-0000000fixt"

#: What the fixtures claim to be. `fixture`/`fixture_title` are outside every
#: real source vocabulary on purpose: a fixture row that matched a production
#: `(source, data_type)` pair could be mistaken for one.
FIXTURE_SOURCE = "fixture"
FIXTURE_DATA_TYPE = "fixture_title"

#: **The profile the cases were written for.** Every title in v2 is a video
#: title, and `source_profile` is a closed enum in the request schema — so this
#: is the profile the model is told to read them as, and it has to match the one
#: the cases' `expect` blocks were labelled under.
FIXTURE_PROFILE = "youtube"
FIXTURE_ACTION = "liked_video"


def argument(name: str, fallback: str) -> str:
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else fallback


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    corpus_path = pathlib.Path(argument("--corpus", str(CORPUS)))
    items_path = pathlib.Path(argument("--items", "out/ris/items_v18.jsonl"))

    corpus = json.loads(corpus_path.read_text())
    cases = corpus["items"]

    # **Taken from the first production row, because every row carries the same
    # inventory.** `ris_build_items.py` stamps one list on all of them; reading
    # it rather than recomputing it is what keeps the two shards describing one
    # ontology.
    first = items_path.read_text().splitlines()[0]
    parents = json.loads(first).get("parent_candidates", [])
    if not parents:
        raise SystemExit(
            f"{items_path} carries no parent_candidates; the fixtures shard "
            "would be scored against a different inventory than the run")

    written = 0
    with out_path.open("w") as handle:
        for case in cases:
            case_id = case["id"]
            handle.write(json.dumps({
                # **The case id is the join.** `score_categorisation.py` finds
                # a case by this value, so anything else here scores nothing
                # and reports it as the model failing.
                "row_id": case_id,
                "user_id": FIXTURE_USER,
                "source_code": FIXTURE_SOURCE,
                "data_type": FIXTURE_DATA_TYPE,
                "item_id": case_id,
                "source_profile": FIXTURE_PROFILE,
                "source_action": FIXTURE_ACTION,
                "fields": {"title": case["title"]},
                "parent_candidates": parents,
            }, ensure_ascii=False) + "\n")
            written += 1

    print(json.dumps({
        "written": written,
        "corpus_version": corpus.get("corpus_version"),
        "parent_candidates": len(parents),
        "parents_from": str(items_path),
        "out": str(out_path),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
