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


#: How many titles travel with a term. **One was the defect** — `JO YURI`
#: appeared in 31 items and was placed on the strength of `Going Under`, an
#: English-titled Apple Music song, while the thirty discarded titles carried
#: 조유리, IZ*ONE, LE SSERAFIM, Mnet and "it's KPOP LIVE". Across the corpus,
#: 2,345 of 3,629 occurrences (65%) were thrown away, and 55 terms seen ten or
#: more times were each reduced to a single sample.
#:
#: Five rather than all of them, because the prompt is a budget and the tail of
#: a K-pop fancam list repeats itself; five distinct titles chosen by frequency
#: is what a person would look at.
MAX_TITLES = 5

#: Predicates that say what a term *belongs to*, and therefore carry a parent.
#: `performed_by` and `created_by` point the other way — from a work to its
#: maker — and are included because that maker's heading is usually the better
#: one for the work: measured, 273 of 491 terms on a broad heading are linked
#: to something placed more specifically.
#: **Ranked, because frequency alone buries the useful one.** Measured on the
#: first build of this file: `JO YURI` carries `member_of_group -> IZ*ONE`, the
#: single fact that settles her heading, and it was cut from her top five by
#: `part_of_franchise -> JOYURI` and `part_of_franchise -> Growls and Purrs` —
#: which are more frequent and say nothing. Membership names a parent; a
#: performance credit names a collaborator.
LINKING = {"member_of_group": 0, "part_of_franchise": 1, "soundtrack_of": 1,
           "composed_by": 2, "created_by": 2,
           "performed_by": 3, "recording_of": 3}


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
            record = picked.get(k)
            if record is None:
                record = picked[k] = {
                    "key": f"{k[0]}|{family}",
                    "label": label,
                    "surface": mention.get("surface"),
                    "family": family,
                    "cardinal": mention.get("selected_cardinal"),
                    "seen": 0,
                    "_titles": collections.Counter(),
                    "_related": collections.Counter(),
                }
            record["seen"] += 1
            if title:
                record["_titles"][title] += 1
            # **The relations travel now, and their absence was the defect.**
            # `JO YURI` carries `member_of_group -> IZ*ONE`, and `IZ*ONE` is
            # placed at `genre:k_pop` in the very file this pass writes. The
            # placement pass could not see it: nothing but the dictionary
            # emitter has ever read `relation_hypotheses`. She was filed under
            # Content creators instead.
            for relation in (mention.get("relation_hypotheses") or []):
                obj = (relation.get("object_label_hypothesis") or "").strip()
                predicate = relation.get("predicate")
                if not obj or predicate not in LINKING:
                    continue
                # **A term is not its own parent.** `Jay Chou part_of_franchise
                # Jay Chou` and `Jay Chou performed_by Jay Chou` were both
                # emitted, and both crowded out something that says where he
                # belongs. Self-reference is a real output of this model and
                # carries no information.
                if key(obj) == k[0]:
                    continue
                record["_related"][(LINKING[predicate], f"{predicate} {obj}")] += 1

    # **Chosen by frequency, then by length, and the second half is not a
    # nicety.** First-writer-wins handed `One Piece` the title `Sen No Yoru Wo
    # Koete`, a bare romaji song name with no anime cue. Ranking by frequency
    # alone did not fix it: all seven of its titles appear once, so the tie
    # broke alphabetically and
    # `洛基真沒說謊騙路飛！他確實能滅掉四皇在內的任何海賊團 #海賊王` — the one
    # title that actually says what One Piece is — sorted last behind `1874`.
    #
    # **An alphabetical tiebreak puts every CJK title behind every Latin one**,
    # in a corpus that is largely CJK. Length is the better second key: a long
    # title carries more signal than a short one, it is deterministic so a
    # replay writes the same file, and it does not encode an alphabet.
    rows = []
    for record in picked.values():
        titles_ranked = sorted(record.pop("_titles").items(),
                               key=lambda kv: (-kv[1], -len(kv[0]), kv[0]))
        # Relations rank by what the predicate is *for* before how often it was
        # said — membership names a parent, a performance credit names a
        # collaborator.
        related_ranked = sorted(record.pop("_related").items(),
                                key=lambda kv: (kv[0][0], -kv[1], kv[0][1]))
        record["context_titles"] = [t for t, _ in titles_ranked[:MAX_TITLES]]
        # Kept so nothing downstream has to change at once, and so the two can
        # be compared: this is the exact string the one-title pass was given.
        record["context_title"] = record["context_titles"][0] if record["context_titles"] else ""
        record["related"] = [r for (_rank, r), _n in related_ranked[:MAX_TITLES]]
        rows.append(record)

    out.write_text(
        "\n".join(json.dumps(p, ensure_ascii=False) for p in rows) + "\n",
        encoding="utf-8")

    families = collections.Counter(p["family"] for p in picked.values())
    print(json.dumps({
        "unparented_mentions": sum(p["seen"] for p in picked.values()),
        "already_parented": already,
        "distinct_terms_to_ask": len(picked),
        "candidates_offered": len(candidates),
        # **What the one-title pass discarded, said out loud.** The baseline it
        # replaces showed the model one occurrence in every case; the gap
        # between these two numbers is the evidence that used to be dropped.
        "titles_shown": sum(len(p["context_titles"]) for p in rows),
        "titles_available": sum(p["seen"] for p in rows),
        "terms_carrying_relations": sum(1 for p in rows if p["related"]),
        "by_family": dict(families.most_common()),
        "out": str(out),
    }, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
