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

**Resolve before place (rung 1 of the ladder, owner 2026-08-24).** A term the
catalogue already publishes takes the catalogue's own parent and is never sent
to the model. Measured need: **1,437 of the 1,475 corpus terms that already
existed as concepts were already parented there** — `creator:jo_yuri -->
genre:k_pop` was published fact while the GPU guessed
`subject:content_creators`. A guess must never stand where an authored fact
exists, and not asking is also simply cheaper.

The catalogue travels as a file, like the closure `ris_parent_merge` takes —
this tool runs beside a GPU, not beside Postgres. Build it with:

    select json_agg(row_to_json(x))::text from (
      select lower(btrim(cr.preferred_label)) as label, c.concept_key,
             (select coalesce(json_agg(pa.concept_key), '[]'::json)
                from ontology.concept_edges e
                join ontology.concepts pa on pa.id = e.object_concept_id
               where e.subject_concept_id = c.id
                 and e.predicate_key = 'broader' and e.status = 'active'
                 and e.ontology_version_id =
                     (select id from ontology.versions where status='published')
             ) as parents
        from ontology.concept_revisions cr
        join ontology.concepts c on c.id = cr.concept_id
       where cr.ontology_version_id =
             (select id from ontology.versions where status = 'published')
         and c.retired_at is null) x;

    python3 tools/ris_parent_build.py verdicts.json items.jsonl parents.jsonl \
            [catalogue.json resolved.jsonl]
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

#: **The inverse direction, and the term it exists for.** `Jekyll & Hyde` the
#: franchise was placed under `genre:pop` with `genre:musicals` on offer and
#: the words "Musical … Cast Recording" in its own prompt — because the
#: franchise record carried `related: []`. Its songs each said
#: `part_of_franchise -> Jekyll & Hyde`; nothing said anything back. A term
#: whose whole identity is "the thing these works belong to" arrived with no
#: structural statement of it, which is the thinnest record a term can have:
#: inference-only, no offsets, no relations.
#:
#: So belonging-type relations now write an inverse line onto the *object's*
#: record — the franchise learns which works it contains, the group which
#: members it has. Maker-type predicates (`performed_by`, `composed_by`) are
#: deliberately absent: a person's record already carries their titles, and
#: "performed X" fifty times over is noise, not identity.
#:
#: The object's family comes from the same predicate map the dictionary
#: emitter states (`_OBJECT_FAMILY_FOR`); copied for the same reason it copies
#: the worker's — this tool must load without psycopg — and the worker's is
#: the copy that governs.
INVERSE = {
    "part_of_franchise": ("franchise", "franchise of"),
    "member_of_group": ("group", "has member"),
    "soundtrack_of": ("work", "soundtrack includes"),
}
#: Below membership (0), above maker-credits (3): what a thing contains is
#: strong evidence of what it is.
INVERSE_RANK = 1

#: **The owner's rule, 2026-08-25, extended the same day to a ladder:
#: person -> franchise -> work.** In one entry, look for the person (or
#: performing group) first; if none, the entry's franchise is the anchor; if
#: no franchise, its work. Strictly a fallback — only the highest non-empty
#: tier anchors, because a lower tier beside a higher one is the thing being
#: anchored, not the anchor.**
#: The rule was bought by the routing queue's own contents: `California`,
#: `Spanish Sahara` and `西西里` were sent to `hub:places_cultures` on their
#: names alone — while `Chappell Roan`, `Foals` and `Jay Chou` stood in the
#: same entries, each already resolvable to a music genre. A song wearing a
#: place name is ambiguous; a song beside its performer is not. The anchor
#: outranks every relation (rank below LINKING's 0), because the person is
#: the one term in an entry whose identity survives ambiguity best — which is
#: the same reason the person subtype pass exists at all.
ANCHOR_RANK = -1

#: The ladder's tiers, highest first, each with the phrase the prompt shows.
#: Work-shaped families all count as the work tier. Note the asymmetry this
#: preserves: a character is family `person`, so an entry holding one anchors
#: *on* the character (tier 1) — parties are anchors, never receivers, and a
#: work tier only ever fires in an entry with no party and no franchise at
#: all.
ANCHOR_TIERS = (
    (("person", "group"), "artist in this entry"),
    (("franchise",), "franchise in this entry"),
    (("work", "anime", "book", "game", "music_work", "album"),
     "work in this entry"),
)


#: Which key prefix each wire family may resolve against — mirrors
#: `ontology.family_mint_convention` (0337), which is the copy that governs.
#: The kind test is what stops `Kate Bush (franchise)` resolving onto
#: `creator:kate_bush`: 315 rows in the deployed dictionary match a published
#: concept by label and disagree with it about what kind of thing it is, and
#: every one is the dictionary being wrong — but resolving across the
#: disagreement would silently launder the wrong family into a link.
FAMILY_PREFIX = {
    "person": "creator", "group": "creator", "organization": "creator",
    "franchise": "work", "work": "work", "anime": "work", "book": "work",
    "game": "work", "music_work": "work", "album": "work",
    "activity": "activity", "sport": "sport", "place": "place",
    "art": "movement", "field": "subject", "culture": "culture",
    "event": "event", "tour": "event",
}


def key(text: str) -> str:
    """The identity two spellings of one term share."""
    return unicodedata.normalize("NFKC", (text or "").strip()).casefold()


def load_catalogue(path: pathlib.Path) -> dict:
    """The published catalogue, re-keyed on this file's own normalisation.

    **Exact identity only, and ambiguity is a refusal.** Two concepts whose
    labels collapse to one key mean the label alone cannot say which is meant,
    and this project has paid twice for resolving that by guessing. The
    ambiguous entry is dropped and counted; the term goes to the model like
    any other.
    """
    raw = json.loads(path.read_text(encoding="utf-8"))
    by_label: dict[str, list] = collections.defaultdict(list)
    for row in raw:
        by_label[key(row.get("label"))].append(row)
    catalogue, ambiguous = {}, 0
    for label_key, rows in by_label.items():
        if not label_key:
            continue
        if len({r["concept_key"] for r in rows}) > 1:
            ambiguous += 1
            continue
        catalogue[label_key] = rows[0]
    return {"by_label": catalogue, "ambiguous_labels": ambiguous}


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
    #: Inverse statements buffered until every record exists — a franchise
    #: mentioned on shard one must still receive members from shard four.
    inverse_buffer: dict[tuple[str, str], collections.Counter] = collections.defaultdict(collections.Counter)
    already = 0
    for verdict in verdicts["verdicts"]:
        title = titles.get(verdict.get("row_id"), "")
        # **The ladder (owner's rule): person -> franchise -> work.** One
        # sweep collects every tier; the highest non-empty tier anchors. A
        # performing group counts as the person tier — `Spanish Sahara`
        # beside `Foals` missed its anchor when only literal persons did.
        tier_labels = {i: [] for i in range(len(ANCHOR_TIERS))}
        for mention in verdict.get("mentions", []):
            fam = mention.get("family_hypothesis")
            lab = (mention.get("canonical_label_hypothesis")
                   or mention.get("surface") or "").strip()
            if not lab:
                continue
            for i, (families, _phrase) in enumerate(ANCHOR_TIERS):
                if fam in families:
                    if key(lab) not in {key(x) for x in tier_labels[i]}:
                        tier_labels[i].append(lab)
                    break
        anchor_tier = next((i for i in range(len(ANCHOR_TIERS))
                            if tier_labels[i]), None)
        persons_in_entry = tier_labels[anchor_tier] if anchor_tier is not None else []
        anchor_families = ANCHOR_TIERS[anchor_tier][0] if anchor_tier is not None else ()
        anchor_phrase = ANCHOR_TIERS[anchor_tier][1] if anchor_tier is not None else ""
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
                    "grounded": False,
                    "english": None,
                    "_titles": collections.Counter(),
                    "_related": collections.Counter(),
                }
            record["seen"] += 1
            # The anchor: every term outside the anchoring tier reads against
            # it. Parties never receive anchors (a duet partner is not an
            # identity), and a tier never anchors its own members.
            if family not in anchor_families and family not in ("person", "group"):
                for person in persons_in_entry:
                    if key(person) != k[0]:
                        record["_related"][(ANCHOR_RANK,
                                           f"{anchor_phrase}: {person}")] += 1
                        record.setdefault("_anchor_persons", set()).add(person)
            # **Grounded means at least one mention carried a span.** The
            # corroboration guard downstream turns on this: a term attested
            # only by inference — the lane the offset checks cannot reach, and
            # the lane the 16 false `One Piece` rows arrived through — may
            # neither receive a new parent nor vote for minting one.
            if mention.get("start") is not None:
                record["grounded"] = True
            record["english"] = record["english"] or mention.get("english_label")
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
                # The inverse: the object learns what points at it.
                if predicate in INVERSE:
                    obj_family, phrase = INVERSE[predicate]
                    inverse_buffer[(key(obj), obj_family)][f"{phrase} {label}"] += 1

    # Apply the buffered inverses now that every record exists. Only onto
    # records that were actually picked — an object that never appeared as a
    # term of its own has nowhere to receive them, and inventing a record for
    # it here would smuggle relation objects back into the ask list.
    inverses_applied = 0
    for target, statements in inverse_buffer.items():
        record = picked.get(target)
        if record is None:
            continue
        for statement, count in statements.items():
            record["_related"][(INVERSE_RANK, statement)] += count
            inverses_applied += 1

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
        # Carried structurally as well as in prose, because the merge inherits
        # along anchors the same way it inherits along relations.
        record["anchor_persons"] = sorted(record.pop("_anchor_persons", set()))
        rows.append(record)

    # ------------------------------------------------------------------
    # Rung 1: resolve against the catalogue before anything reaches a GPU
    # ------------------------------------------------------------------
    resolved: list[dict] = []
    kind_refused = 0
    catalogue = None
    if len(sys.argv) > 4:
        catalogue = load_catalogue(pathlib.Path(sys.argv[4]))
        remaining = []
        for record in rows:
            # **The English identity first, the canonical second** — the same
            # order the resolver in 0340 and the emitter's identity merge use,
            # because the catalogue's labels are English where one exists.
            entry = (catalogue["by_label"].get(key(record.get("english") or ""))
                     or catalogue["by_label"].get(key(record["label"])))
            wanted = FAMILY_PREFIX.get(record["family"])
            if entry is None or wanted is None:
                remaining.append(record)
                continue
            prefix = str(entry["concept_key"]).split(":", 1)[0]
            if prefix != wanted:
                # A label match whose kind disagrees is the dictionary being
                # wrong about what the thing is; refusing keeps the wrong
                # family from laundering into a link. Counted, never silent.
                kind_refused += 1
                remaining.append(record)
                continue
            if not entry.get("parents"):
                # Exists but unparented — 38 such concepts at last count. The
                # link is the resolver's job (0340, in the database); *this*
                # pass only skips the question when the catalogue already
                # answers it, and here it does not.
                remaining.append(record)
                continue
            resolved.append({
                "key": record["key"], "label": record["label"],
                "family": record["family"], "seen": record["seen"],
                "grounded": record["grounded"],
                "concept_key": entry["concept_key"],
                "parents": entry["parents"],
                "parent_source": "catalogue",
            })
        rows = remaining

    if len(sys.argv) > 5 and resolved:
        pathlib.Path(sys.argv[5]).write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in resolved) + "\n",
            encoding="utf-8")

    out.write_text(
        "\n".join(json.dumps(p, ensure_ascii=False) for p in rows) + "\n",
        encoding="utf-8")

    families = collections.Counter(p["family"] for p in picked.values())
    print(json.dumps({
        "unparented_mentions": sum(p["seen"] for p in picked.values()),
        "already_parented": already,
        "distinct_terms_to_ask": len(rows),
        # **The split, said out loud** — the proportion the model is actually
        # needed for is the number this report exists to make visible.
        "resolved_from_catalogue": len(resolved),
        "refused_kind_mismatch": kind_refused,
        "catalogue_ambiguous_labels": (catalogue or {}).get("ambiguous_labels", 0),
        "candidates_offered": len(candidates),
        # **What the one-title pass discarded, said out loud.** The baseline it
        # replaces showed the model one occurrence in every case; the gap
        # between these two numbers is the evidence that used to be dropped.
        "titles_shown": sum(len(p["context_titles"]) for p in rows),
        "titles_available": sum(p["seen"] for p in rows),
        "terms_carrying_relations": sum(1 for p in rows if p["related"]),
        "inverse_statements_applied": inverses_applied,
        "terms_carrying_anchor_person": sum(1 for p in rows if p["anchor_persons"]),
        "by_family": dict(families.most_common()),
        "out": str(out),
    }, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
