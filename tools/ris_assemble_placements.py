#!/usr/bin/env python3
"""Union the cascade's stages per hub, instead of letting the last one win.

**The owner's rule (2026-08-25): one placement per hub, any number of
hubs** — a term counts toward a genre and a movement at once. A correction is
part of this file's record: the first diagnosis claimed the eight holdout
misses were stage collisions with the truth held by an earlier stage. That
table was contaminated — the "truth-holding" rows were the catalogue
pseudo-anchors, i.e. the answer key itself, present because holdout terms are
catalogue-resolved by construction. Measured honestly, the original three
stages produce **zero** cross-hub disagreements on this corpus, so the rule
is realised by a fourth stage: the cross-hub second ask, run wherever a
term's anchor sits in a hub the term holds no placement in — the anchor
audit's 126 flagged pairs (Persona 5 at role_playing_game beside its singer
at soundtrack) being the genuine instances.

Per term: collect every stage's specific placement, bucket each by its
heading's closure hub-ancestor (a heading outside every hub buckets as
itself), and within a bucket keep the highest-priority stage —
round-3 within-hub > inherited > rung-2 — because within one hub the later
stage really did answer the same question more deeply. Across buckets nothing
competes; that is the rule.

The primary placement keeps today's exact semantics (last stage wins), so the
single-column readers see nothing move.

    python3 tools/ris_assemble_placements.py rung2_answers.jsonl[,more.jsonl] \\
        merged.jsonl replace_dir closure.json out_placements.jsonl
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys

STAGE_PRIORITY = {"crosshub": 3, "round3": 3, "inherited": 2, "rung2": 1}


def hub_of(heading: str, ancestors: dict) -> str:
    hubs = [a for a in (ancestors.get(heading) or ()) if a.startswith("hub:")]
    return hubs[0] if hubs else heading


def main() -> int:
    rung2_paths = [pathlib.Path(p) for p in sys.argv[1].split(",")]
    merged_path = pathlib.Path(sys.argv[2])
    replace_dir = pathlib.Path(sys.argv[3])
    ancestors = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
    out_path = pathlib.Path(sys.argv[5])
    # The cross-hub second ask (owner's rule): answers in the anchor's hub,
    # which is the stage that actually produces multiples — the original
    # three stages measured zero cross-hub disagreements on this corpus.
    crosshub_dir = pathlib.Path(sys.argv[6]) if len(sys.argv) > 6 else None

    terms: dict = {}

    def offer(record: dict, parent: str, stage: str, confidence):
        if not parent or parent in ("none", "needs_new_parent"):
            return
        # **A bare hub is routing, not placement.** The whole framework treats
        # hub-level answers as "unplaced, ask further"; letting one occupy a
        # bucket would judge routing as an assignment — measured: it turned 24
        # abstentions into fake misassignments in one evaluation run.
        if parent.startswith("hub:"):
            return
        key = record["key"]
        entry = terms.setdefault(key, {
            "key": key, "label": record.get("label"),
            "family": record.get("family"), "buckets": {},
            "last": None})
        bucket = hub_of(parent, ancestors)
        held = entry["buckets"].get(bucket)
        if held is None or STAGE_PRIORITY[stage] > STAGE_PRIORITY[held["stage"]]:
            entry["buckets"][bucket] = {
                "parent": parent, "hub": bucket, "stage": stage,
                "confidence": confidence}
        # The primary mirrors the old assembly exactly: latest stage wins
        # globally, so single-column readers see the same answer as before.
        if entry["last"] is None or STAGE_PRIORITY[stage] >= STAGE_PRIORITY[entry["last"][1]]:
            entry["last"] = (parent, stage, confidence)

    for path in rung2_paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                a = json.loads(line)
                offer(a, a.get("parent"), "rung2", a.get("confidence"))
    for line in merged_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        a = json.loads(line)
        if a.get("parent_source") == "catalogue":
            continue
        stage = "inherited" if a.get("parent_source") == "inherited" else "rung2"
        offer(a, a.get("parent"), stage, a.get("confidence"))
    for path in sorted(replace_dir.glob("replace_*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                a = json.loads(line)
                offer(a, a.get("parent"), "round3", a.get("confidence"))
    if crosshub_dir and crosshub_dir.exists():
        for path in sorted(crosshub_dir.glob("crosshub_*.jsonl")):
            for line in path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    a = json.loads(line)
                    offer(a, a.get("parent"), "crosshub", a.get("confidence"))

    rows = []
    multi = 0
    for entry in terms.values():
        placements = sorted(entry["buckets"].values(),
                            key=lambda p: -STAGE_PRIORITY[p["stage"]])
        if len(placements) > 1:
            multi += 1
        rows.append({
            "key": entry["key"], "label": entry["label"],
            "family": entry["family"],
            "primary": entry["last"][0],
            "primary_confidence": entry["last"][2],
            "placements": placements,
        })
    out_path.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n",
        encoding="utf-8")

    hubs = collections.Counter(
        p["hub"] for r in rows for p in r["placements"])
    print(json.dumps({
        "terms": len(rows),
        "terms_with_multiple_hubs": multi,
        "total_placements": sum(len(r["placements"]) for r in rows),
        "top_buckets": dict(hubs.most_common(8)),
        "out": str(out_path),
    }, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
