#!/usr/bin/env python3
"""Score the framework's assignments — against ground truth where it exists.

**The measurement the framework has owed since it was built.** Acceptance rates
measure well-formedness; fixtures measure eleven invented cases; neither says
how often a real term lands under the wrong heading. Two measures fix that,
one exact and one structural:

* **The holdout (exact).** 200 terms the catalogue already parents — authored
  ground truth — had their resolution stripped and were run through the full
  cascade blind. Assigned == an authored parent is *exact*; assigned an
  ancestor/descendant of one is *congruent* (a broader-but-true heading is what
  a heading is); `none` is an *abstention*, which is the designed behaviour for
  a thin record and is counted apart from error; anything else is a
  **misassignment**, and that rate is the number the owner asked for.

* **Anchor congruency (structural, whole-corpus).** The owner's ladder says an
  entry's terms read against its anchor. Where both a term and its anchor hold
  placements, they should be closure-related — the term's heading an ancestor,
  descendant, or sibling-under-one-genre of the anchor's. A term placed at
  `subject:travel` whose anchor sits at `genre:mandopop` is flagged. Not proof
  of error — a soundtrack song beside a film franchise legitimately splits —
  but a rate to watch and a list to read.

The owner-review sample closes the loop the golden set opened: a stratified
draw across dispositions, written as TSV for hand-labelling, because the
project's accuracy numbers have only ever come from the owner labelling draws.

    python3 tools/ris_evaluate_assignments.py final_answers.jsonl \\
        out/ris/holdout_truth.json holdout_answers.jsonl \\
        out/ris/broader_closure.json out/ris/v19_resolved.jsonl review.tsv
"""
from __future__ import annotations

import collections
import json
import pathlib
import random
import sys
import unicodedata


def key(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "").strip()).casefold()


def related(a: str, b: str, ancestors: dict) -> bool:
    """Closure-related: identical, ancestor either way, or same genre parent."""
    if a == b:
        return True
    anc_a = set(ancestors.get(a) or ())
    anc_b = set(ancestors.get(b) or ())
    if b in anc_a or a in anc_b:
        return True
    # Siblings under one non-hub heading count: two songs of one genre.
    shared = (anc_a & anc_b) - {x for x in anc_a & anc_b if x.startswith("hub:")}
    return bool(shared)


def main() -> int:
    answers = [json.loads(l) for l
               in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
               if l.strip()]
    truth = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    holdout = [json.loads(l) for l
               in pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines()
               if l.strip()]
    ancestors = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
    resolved = {json.loads(l)["key"]: json.loads(l) for l
                in pathlib.Path(sys.argv[5]).read_text(encoding="utf-8").splitlines()
                if l.strip()}
    review_path = pathlib.Path(sys.argv[6])
    # **Anchors live on the term records, not the answers** — the first run of
    # this checked zero terms because it read `anchor_persons` off answer rows
    # that never carried it. Joined from the build's records instead.
    anchors_by_key = {}
    if len(sys.argv) > 7:
        for l in pathlib.Path(sys.argv[7]).read_text(encoding="utf-8").splitlines():
            if l.strip():
                r = json.loads(l)
                anchors_by_key[r["key"]] = r.get("anchor_persons") or []

    # ------------------------------------------------------------------
    # 1. The holdout: exact misassignment against authored truth
    # ------------------------------------------------------------------
    exact = congruent = abstained = routed = misassigned = 0
    misses = []
    for answer in holdout:
        t = truth.get(answer["key"])
        if not t:
            continue
        # Any-placement scoring (owner's rule): a term with per-hub
        # placements is judged on its best one — one may be a screen genre
        # and another the authored music genre, and both being held is the
        # design, not a tie to break.
        candidates = [answer.get("parent")] if answer.get("parent") else []
        for pl in answer.get("placements") or ():
            if pl.get("parent") and pl["parent"] not in candidates:
                candidates.append(pl["parent"])
        assigned = candidates[0] if candidates else None
        authored = [p for p in t["parents"]
                    if not p.split(":")[0] in ("era", "sphere", "scene")]
        real = [c for c in candidates if c not in ("none", "needs_new_parent")]
        if not real:
            if "needs_new_parent" in candidates:
                routed += 1
            else:
                abstained += 1
        elif any(c in authored for c in real):
            exact += 1
        elif any(related(c, p, ancestors) for c in real for p in authored):
            congruent += 1
        else:
            misassigned += 1
            misses.append((answer["key"], real, authored))
    judged = exact + congruent + misassigned
    holdout_report = {
        "holdout_terms": len(holdout),
        "exact": exact, "congruent": congruent,
        "abstained": abstained, "routed": routed,
        "misassigned": misassigned,
        "misassignment_rate_of_judged":
            round(misassigned / judged, 4) if judged else None,
    }

    # ------------------------------------------------------------------
    # 2. Anchor congruency across the whole corpus
    # ------------------------------------------------------------------
    placement = {}
    for answer in answers:
        p = answer.get("parent")
        if p and p not in ("none", "needs_new_parent"):
            placement[answer["key"]] = p
    for r in resolved.values():
        heads = [p for p in r.get("parents") or ()
                 if not p.split(":")[0] in ("era", "sphere", "scene")]
        if heads:
            placement[r["key"]] = heads[0]
    by_label = collections.defaultdict(set)
    for k, p in placement.items():
        by_label[k.rsplit("|", 1)[0]].add(p)

    checked = agree = flagged = 0
    flags = []
    for answer in answers:
        p = placement.get(answer["key"])
        if not p:
            continue
        for anchor in (answer.get("anchor_persons")
                       or anchors_by_key.get(answer["key"]) or ()):
            targets = by_label.get(key(anchor))
            if not targets:
                continue
            checked += 1
            if any(related(p, t, ancestors) for t in targets):
                agree += 1
            else:
                flagged += 1
                if len(flags) < 40:
                    flags.append((answer["key"], p, anchor, sorted(targets)))
            break  # one anchor check per term: the ladder's top anchor
    anchor_report = {
        "terms_checked_against_anchor": checked,
        "congruent_with_anchor": agree,
        "flagged_incongruent": flagged,
        "incongruence_rate": round(flagged / checked, 4) if checked else None,
    }

    # ------------------------------------------------------------------
    # 3. The owner-review sample: stratified, deterministic, hand-labelable
    # ------------------------------------------------------------------
    random.seed(19)
    strata = collections.defaultdict(list)
    for answer in answers:
        p = answer.get("parent") or "none"
        bucket = ("none" if p == "none" else
                  "routed" if p == "needs_new_parent" else
                  "hub" if p.startswith("hub:") else "specific")
        strata[bucket].append(answer)
    lines = ["key\tlabel\tfamily\tassigned\tanchor\towner_verdict(ok/wrong/unsure)"]
    for bucket, take in (("specific", 24), ("none", 8), ("hub", 4), ("routed", 4)):
        pool = strata.get(bucket, [])
        for answer in random.sample(pool, min(take, len(pool))):
            anchor = ((answer.get("anchor_persons")
                       or anchors_by_key.get(answer["key"]) or [""]) + [""])[0]
            lines.append("\t".join([
                answer["key"], answer.get("label", ""), answer.get("family", ""),
                answer.get("parent") or "none", anchor, ""]))
    review_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(json.dumps({"holdout": holdout_report, "anchor": anchor_report,
                      "review_sample": str(review_path)},
                     indent=1, ensure_ascii=False))
    print("\nholdout misassignments (term, assigned, authored):")
    for k, a, t in misses[:20]:
        shown = a if isinstance(a, str) else ", ".join(a)
        print(f"  {k[:34]:<36} {shown:<40} truth={t}")
    print("\nanchor-incongruent samples:")
    for k, p, anchor, targets in flags[:12]:
        print(f"  {k[:30]:<32} at {p:<24} anchor {anchor[:20]:<22} -> {targets[:2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
