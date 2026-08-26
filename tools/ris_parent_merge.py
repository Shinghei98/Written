#!/usr/bin/env python3
"""Move a term off a heading its own evidence says is too broad.

**The measurement this exists for.** Of the 1,262 terms the placement pass
placed in David's run, **491 landed on a broad heading** — 347 of them on
`hub:music` alone, which for a library of Baroque, K-pop and Mandopop says
almost nothing. And **273 of those 491 are linked, by a relation the extraction
already emitted, to a term that was placed more specifically**:

    Candy          (music_work) hub:music  --performed_by-->  H.O.T.    genre:k_pop
    River in the Sky (work)     hub:music  --performed_by-->  JJ Lin    genre:mandopop
    Caffeine       (music_work) hub:music  --performed_by-->  Yang Yo-seob  genre:k_pop

The song is filed under Music; the singer under K-Pop. Nothing joined them,
because nothing but the dictionary emitter has ever read `relation_hypotheses`.

**Demotion only, and the direction is the whole safety property.** A term moves
*down* the published tree — from an ancestor to a descendant — and never up. So
`hub:music -> genre:k_pop` is allowed and `genre:k_pop -> hub:music` is refused,
which means a well-placed term can never be made vaguer by a badly-placed
neighbour. `Itzhak Perlman` at `genre:classical` linked to a piece at
`genre:opera` stays at classical: opera is not a descendant of classical, so
there is no move to make.

**Ancestry comes from the tree, not from a list of "broad" headings.** A
hand-written list is a judgement that goes stale the moment the ontology grows;
`broader` closure is the catalogue's own answer. Build the closure file with:

    with recursive edges as (
      select e.subject_concept_id as child, e.object_concept_id as parent
        from ontology.concept_edges e
       where e.predicate_key = 'broader' and e.status = 'active'
         and e.ontology_version_id =
             (select id from ontology.versions where status = 'published')),
    closure as (
      select child, parent, 1 as depth from edges
      union all
      select c.child, e.parent, c.depth + 1
        from closure c join edges e on e.child = c.parent
       where c.depth < 6)
    select jsonb_object_agg(k, v) from (
      select ch.concept_key as k, jsonb_agg(distinct pa.concept_key) as v
        from closure cl
        join ontology.concepts ch on ch.id = cl.child
        join ontology.concepts pa on pa.id = cl.parent
       group by 1) t;

    python3 tools/ris_parent_merge.py answers.jsonl verdicts.json \
            closure.json merged.jsonl
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys
import unicodedata

#: **Inheritance has a direction, and getting it wrong narrows a performer to
#: one piece they played.** Measured on the first run of this: `Hilary Hahn`
#: moved from `genre:classical` to `genre:baroque` because she performed a Bach
#: work — but she plays Romantic repertoire too, and a violinist is not the
#: genre of any one recording. `Leonard Bernstein` went the same way.
#:
#: The asymmetry is the emitter's own rule about membership, applied to
#: headings: **a work belongs to its maker's world; a maker does not belong to
#: one work's.** So:
#:
#:   * a **work, album or recording** inherits from whoever made it —
#:     `performed_by`, `composed_by`, `created_by`, `soundtrack_of`;
#:   * a **person, group or organization** inherits only from something it is
#:     *inside* — `member_of_group`, `part_of_franchise`. JO YURI takes IZ*ONE's
#:     heading; she does not take her own single's.
#:
#: A predicate absent from a subject's list is not an error, it is a refusal.
PARTY = {"person", "group", "organization"}
#: **A person inherits only from a group they are in.** `part_of_franchise`
#: reads as belonging and is emitted loosely: the model wrote `Hilary Hahn
#: part_of_franchise Bach`, meaning she plays Bach, and that alone moved her
#: from `genre:classical` to `genre:baroque` — a violinist with a Romantic
#: repertoire narrowed to one composer she records. A person cannot be *part
#: of* a person, and `member_of_group` is the one predicate whose whole meaning
#: is belonging, which is why the dictionary emitter's `_is_membership` trusts
#: it and nothing else.
PARTY_INHERITS = ("member_of_group",)
BELONGS_TO = ("member_of_group", "part_of_franchise")
MADE_BY = ("performed_by", "composed_by", "created_by", "soundtrack_of",
           "recording_of")
LINKING = BELONGS_TO + MADE_BY


def inheritable(family: str) -> tuple:
    """Which predicates may carry a heading *to* a term of this family."""
    return PARTY_INHERITS if family in PARTY else LINKING


def key(text: str) -> str:
    return unicodedata.normalize("NFKC", (text or "").strip()).casefold()


def main() -> int:
    answers = [json.loads(line) for line
               in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
               if line.strip()]
    verdicts = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    #: {concept_key: [every ancestor's concept_key]}
    ancestors = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
    out_path = pathlib.Path(sys.argv[4])
    # **Tier 2's substrate (GRAMMARBOOK 2.18, built 2026-08-26): the standing
    # catalogue's own placements**, {label_key: [parent_concept_key]} exported
    # from the published version. Without it a linked term binds only when
    # *this round* also placed it; with it the join reaches everything the
    # catalogue already knows. Optional: absent, the pass behaves as before.
    catalogue_by_label: dict = {}
    if len(sys.argv) > 5:
        catalogue_by_label = {
            k: set(v) for k, v in json.loads(
                pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")).items()}

    placed = {}
    for answer in answers:
        parent = answer.get("parent")
        # `needs_new_parent` routes a term to the proposal pass; it is
        # neither a placement to index nor one to improve.
        if parent and parent not in ("none", "needs_new_parent"):
            placed[(key(answer.get("label")), answer.get("family"))] = parent

    # **A term's heading looked up by label alone, across families.** Where a
    # relation names `JJ Lin`, the extraction did not record which family it
    # meant, so the object is matched on the name. Where two families disagree
    # about one name, the most specific shared answer is not obvious and the
    # pairing is refused below rather than guessed.
    by_label: dict[str, set] = collections.defaultdict(set)
    for label_key, parents in catalogue_by_label.items():
        by_label[label_key] |= parents
    for (label_key, _family), parent in placed.items():
        by_label[label_key].add(parent)

    links: dict[tuple, set] = collections.defaultdict(set)
    for verdict in verdicts["verdicts"]:
        # **The owner's rule, 2026-08-25: the entry's person anchors every
        # other term in it.** `California` beside `Chappell Roan` is her song,
        # whatever its name says; the person's placement flows to the entry's
        # works exactly as an explicit `performed_by` would flow it. Persons do
        # not anchor persons (a duet partner is not an identity), which is the
        # same PARTY rule the explicit relations already obey.
        # The ladder: person -> franchise -> work; the highest non-empty
        # tier anchors, and only that tier.
        tiers = (("person", "group"), ("franchise",),
                 ("work", "anime", "book", "game", "music_work", "album"))
        persons_in_entry: set = set()
        anchor_families: tuple = ()
        for tier in tiers:
            found = {
                key(m.get("canonical_label_hypothesis") or m.get("surface") or "")
                for m in verdict.get("mentions", [])
                if m.get("family_hypothesis") in tier}
            found.discard("")
            if found:
                persons_in_entry, anchor_families = found, tier
                break
        for mention in verdict.get("mentions", []):
            family = mention.get("family_hypothesis")
            label = (mention.get("canonical_label_hypothesis")
                     or mention.get("surface") or "")
            subject = (key(label), family)
            if not family or not subject[0]:
                continue
            allowed = inheritable(family)
            for relation in (mention.get("relation_hypotheses") or []):
                if relation.get("predicate") not in allowed:
                    continue
                obj = key(relation.get("object_label_hypothesis"))
                if obj and obj != subject[0]:
                    links[subject].add(obj)
            # The anchor links: the entry's anchor tier, for subjects outside
            # both that tier and the party set.
            if family not in PARTY and family not in anchor_families:
                links[subject] |= {p for p in persons_in_entry
                                   if p != subject[0]}

    moved = refused_ambiguous = refused_not_descendant = unlinked = 0
    changes = []
    flags: list = []
    # **Iterate to a fixed point (the ladder's pass-2 rule).** A term bound
    # this sweep is context for the next: wu hao's group resolves first, and
    # only then can the group's heading reach the terms that named wu hao.
    # Bounded — each sweep must move something, and five sweeps outruns any
    # real dependency chain this corpus has produced.
    for _sweep in range(5):
        moved_before = moved
        refused_ambiguous = refused_not_descendant = unlinked = 0
        for answer in answers:
            parent = answer.get("parent")
            if not parent or parent in ("none", "needs_new_parent"):
                continue
            subject = (key(answer.get("label")), answer.get("family"))
            # Every heading the linked terms sit on.
            candidates = set()
            for obj in links.get(subject, ()):
                candidates |= by_label.get(obj, set())
            candidates.discard(parent)
            if not candidates:
                unlinked += 1
                continue

            # **A party's stated membership BINDS (the ladder's tier 1, owner
            # 2026-08-25).** For a person or group whose entry stated a
            # `member_of_group` whose group's heading is known, the group's
            # heading wins *even across branches* — wu hao's evidence named the
            # Hao Xuan Peking Opera group and the model still chose Cantonese
            # opera; structure beats the model, and a contradiction is flagged,
            # never silently applied over. Two distinct group headings still
            # refuse: ambiguity holds, as everywhere.
            if answer.get("family") in PARTY:
                # A bare hub is routing, not placement (§2.15) — a group whose
                # own answer this round was a hub must not drag its members off
                # a specific heading. Measured on the first binding run: IVE's
                # bare hub:music pulled two members off genre:k_pop.
                distinct = sorted(c for c in candidates if not c.startswith("hub:"))
                if len(distinct) == 1:
                    bound = distinct[0]
                    contradicts = (parent != bound
                                   and parent not in (ancestors.get(bound) or ()))
                    changes.append((answer["key"], parent, bound))
                    if contradicts:
                        flags.append({
                            "key": answer["key"], "label": answer.get("label"),
                            "model_said": parent, "bound_to": bound,
                            "via": "member_of_group"})
                    answer["parent"] = bound
                    answer["parent_source"] = "inherited"
                    answer["parent_inherited_from"] = parent
                    moved += 1
                else:
                    refused_ambiguous += 1
                continue

            # **Keep only headings strictly below this one.** `parent in
            # ancestors[c]` is the test, and it is asymmetric on purpose: it admits
            # `hub:music -> genre:k_pop` and refuses the reverse.
            deeper = [c for c in candidates if parent in (ancestors.get(c) or ())]
            if not deeper:
                refused_not_descendant += 1
                continue
            if len(deeper) > 1:
                # **Two descendants and no way to choose is a refusal.** Picking
                # the deepest would be inventing a tiebreak, and a term filed under
                # the wrong specific heading reads more confident than one left
                # under a broad one — the failure this whole pass exists to avoid,
                # made worse.
                refused_ambiguous += 1
                continue

            changes.append((answer["key"], parent, deeper[0]))
            answer["parent"] = deeper[0]
            answer["parent_source"] = "inherited"
            answer["parent_inherited_from"] = parent
            moved += 1


        # The sweep's placements join the context for the next sweep.
        if moved == moved_before:
            break
        for answer in answers:
            parent = answer.get("parent")
            if parent and parent not in ("none", "needs_new_parent"):
                by_label[key(answer.get("label"))].add(parent)

    out_path.write_text(
        "\n".join(json.dumps(a, ensure_ascii=False) for a in answers) + "\n",
        encoding="utf-8")
    # The binding contradictions, beside the output: the report artifact the
    # ladder promises — a model answer overridden by stated membership is a
    # fact somebody reads, never a silent replacement.
    flags_path = out_path.with_suffix(".flags.jsonl")
    flags_path.write_text(
        "\n".join(json.dumps(f, ensure_ascii=False) for f in flags)
        + ("\n" if flags else ""), encoding="utf-8")

    print(json.dumps({
        "binding_flags": len(flags),
        "answers": len(answers),
        "moved_to_a_more_specific_heading": moved,
        "refused_no_linked_term_placed": unlinked,
        "refused_link_not_a_descendant": refused_not_descendant,
        "refused_two_descendants_no_tiebreak": refused_ambiguous,
        "out": str(out_path),
    }, indent=1))
    for term, was, now in changes[:15]:
        print(f"  {term[:34]:<36} {was:<22} -> {now}")
    if len(changes) > 15:
        print(f"  ... and {len(changes) - 15} more")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
