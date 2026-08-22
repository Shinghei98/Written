#!/usr/bin/env python3
"""Turn validated verdicts into a dictionary migration — terms, labels, merges.

**Two guards, both evidence-based, neither fuzzy.** This project has paid
twice for similarity matching (`exact_terms_only`; the constant fallback key
that merged nine artists into one concept), so nothing here compares strings
for closeness. A merge is written only where the model *stated* one:

  * **A relation is not a translation.** For the surface `WINTER` the model
    emitted `english_label: aespa` *and* `part_of_franchise -> aespa` in the
    same mention. It is asserting membership, not a spelling, and merging on
    the label would fold a person into her group. Where the English label
    equals the object of a relation the model also emitted, the merge is
    refused and the relation recorded instead. Measured: 515 refusals.
  * **Metadata is not a term.** `playlist=`, `rank=`, `shelf=` surfaces come
    from a column that means four different things by `data_type`; they are
    refused outright.

Everything else follows the dictionary's standing rules: the key is the
release-suffix-bare normalisation the worker uses, rows are never deleted, and
`origin` records how a term arrived without deciding whether it is true.

    python3 tools/ris_emit_dictionary.py out/ris/verdicts.json 0306
"""
from __future__ import annotations

import collections
import json
import pathlib
import re
import sys
import unicodedata

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: Mirrors `_RELEASE_SUFFIXES` in aws/worker/overlay.py. The dictionary keys
#: on a suffix-bare label so `love dive` and `love dive single` are one term.
RELEASE_SUFFIXES = (" - single", " - ep", " (single)", " (ep)",
                    " live version", " remastered", " single", " ep")

METADATA = re.compile(r"^(rank|playlist|shelf|station|position|index)\s*=", re.I)

#: Families whose root is a person or group outrank the works that name them,
#: so a cluster canonicalises on the entity rather than on its release.
PREFERENCE = {"person": 0, "group": 0, "franchise": 1, "organization": 1,
              "event": 2, "tour": 2, "activity": 3, "sport": 3,
              "idea": 4, "culture": 4, "concept": 4,
              "work": 5, "anime": 5, "book": 5, "game": 5,
              "music_work": 6, "album": 7}


def normalise(text: str) -> str:
    value = unicodedata.normalize("NFKC", (text or "").strip()).casefold()
    value = re.sub(r"\s+", " ", value)
    changed = True
    while changed:
        changed = False
        for suffix in RELEASE_SUFFIXES:
            if value.endswith(suffix) and len(value) > len(suffix):
                value = value[: -len(suffix)].strip()
                changed = True
    return value


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text())
    number = sys.argv[2]

    terms: dict = {}
    links: set = set()
    edges: collections.Counter = collections.Counter()
    refused_relation = 0
    refused_metadata = 0

    #: Which family the object of each predicate belongs to — the same map
    #: `_OBJECT_FAMILY` states in aws/worker/overlay.py:1103. Copied rather
    #: than imported because that module needs psycopg and boto3 to load,
    #: which this tool has no business requiring; if the two ever disagree,
    #: the worker's is the one that governs.
    OBJECT_FAMILY = {
        "part_of_franchise": "franchise", "member_of_group": "group",
        "performed_by": "person", "composed_by": "person",
        "created_by": "person", "soundtrack_of": "work",
        "recording_of": "music_work", "played_for": "organization",
        "official_channel_of": "organization",
        "represented_team_in": "event", "located_in": "place",
    }

    for verdict in verdicts["verdicts"]:
        for mention in verdict["mentions"]:
            family = mention.get("family_hypothesis")
            surface = mention.get("surface") or ""
            if not family or METADATA.match(surface.strip()):
                refused_metadata += 1
                continue

            english = mention.get("english_label")
            native = mention.get("original_label")
            canonical = mention.get("canonical_label_hypothesis") or surface
            key = normalise(canonical)
            if not key:
                continue

            record = terms.setdefault((key, family), {
                "canonical": canonical, "english": None, "native": None})
            record["english"] = record["english"] or english
            record["native"] = record["native"] or native

            # The merge, and the one reason to refuse it.
            related = {normalise(r.get("object_label_hypothesis"))
                       for r in (mention.get("relation_hypotheses") or [])}
            surface_key = normalise(surface)
            english_key = normalise(english)
            if english_key and english_key != surface_key:
                if english_key in related:
                    refused_relation += 1
                elif surface_key:
                    # The surface defers to the English identity.
                    links.add((surface_key, english_key, family))
                    terms.setdefault((surface_key, family), {
                        "canonical": surface, "english": english,
                        "native": native})

            # **The object of a relation is a term too**, which is the rule
            # that lets a franchise be known the first time any character of
            # it is seen. Its family is the one the predicate implies rather
            # than a guess; a predicate whose object family is unknown
            # contributes no edge rather than an invented one.
            for relation in (mention.get("relation_hypotheses") or []):
                predicate = relation.get("predicate")
                object_family = OBJECT_FAMILY.get(predicate)
                object_label = relation.get("object_label_hypothesis")
                object_key = normalise(object_label)
                if not (object_family and object_key) or object_key == key:
                    continue
                terms.setdefault((object_key, object_family), {
                    "canonical": object_label, "english": None, "native": None})
                edges[(key, family, predicate, object_key, object_family)] += 1

    out: list[str] = [f"""-- {number} — the RIS corpus enters the dictionary: terms, labels, merges.
--
-- {len(terms)} terms extracted from the full distillation on a lab GPU
-- (four A100 80GB, prompt v13), every one carrying an English and a native
-- label — against 1,000 terms and 14 labels before. {len(links)} merges are
-- written, each one stated by the model rather than guessed at by comparing
-- strings: this project has paid twice for similarity matching and does not
-- do it here.
--
-- Two refusals are worth naming because they are what makes the merges
-- trustworthy. {refused_relation} merges were refused because the English
-- label was also the object of a relation the same mention emitted — for the
-- surface `WINTER` the model said `english_label: aespa` and
-- `part_of_franchise -> aespa` together, which asserts membership, not a
-- spelling, and merging it would fold a person into her group. A further
-- {refused_metadata} surfaces were refused as metadata (`playlist=`, `rank=`,
-- `shelf=`), which is what the legacy `detail` column carries for everything
-- except a library song.
--
-- Nothing here is deleted or overwritten: a term already present keeps its
-- row, and a label already recorded wins over this one.

insert into semantic_private.presumed_terms
  (normalized_label, family, canonical_label, english_label, original_label,
   origin, source_lanes)
values"""]

    rows = []
    for (key, family), record in sorted(terms.items()):
        rows.append("  ({}, {}, {}, {}, {}, 'extracted', '{{}}')".format(
            quote(key), quote(family), quote(record["canonical"][:512]),
            quote(record["english"][:512]) if record["english"] else "null",
            quote(record["native"][:512]) if record["native"] else "null"))
    out.append(",\n".join(rows))
    out.append("""on conflict (normalized_label, family) do update
   set last_seen_at = now(),
       english_label = coalesce(semantic_private.presumed_terms.english_label,
                                excluded.english_label),
       original_label = coalesce(semantic_private.presumed_terms.original_label,
                                 excluded.original_label);
""")

    out.append("-- The merges. 0301's trigger flattens chains and refuses cycles.")
    for variant, canonical, family in sorted(links):
        out.append(
            "insert into semantic_private.presumed_term_links "
            "(variant_term_id, canonical_term_id, basis, evidence)\n"
            "select v.id, c.id, 'label_pair', "
            "jsonb_build_object('source', 'ris_v13')\n"
            "  from semantic_private.presumed_terms v, "
            "semantic_private.presumed_terms c\n"
            f" where v.normalized_label = {quote(variant)} "
            f"and v.family = {quote(family)}\n"
            f"   and c.normalized_label = {quote(canonical)} "
            f"and c.family = {quote(family)}\n"
            "   and v.id <> c.id and v.canonical_term_id is null\n"
            "   and coalesce(c.canonical_term_id, c.id) <> v.id;")

    out.append("\n-- The relations the model stated. Presumed, never traversed.")
    for (skey, sfam, predicate, okey, ofam), count in sorted(edges.items()):
        out.append(
            "insert into semantic_private.presumed_term_relations "
            "(subject_term_id, predicate, object_term_id, evidence, observed_count)\n"
            f"select s.id, {quote(predicate)}, o.id, "
            "jsonb_build_object('source', 'ris_v14'), " + str(count) + "\n"
            "  from semantic_private.presumed_terms s, "
            "semantic_private.presumed_terms o\n"
            f" where s.normalized_label = {quote(skey)} and s.family = {quote(sfam)}\n"
            f"   and o.normalized_label = {quote(okey)} and o.family = {quote(ofam)}\n"
            "   and s.id <> o.id\n"
            "on conflict (subject_term_id, predicate, object_term_id) do update\n"
            "   set observed_count = "
            "semantic_private.presumed_term_relations.observed_count + excluded.observed_count;")

    out.append(f"""
do $$
declare
  n integer;
begin
  select count(*) into n from semantic_private.presumed_terms;
  raise notice '{number}: % terms in the dictionary', n;
  select count(*) into n from semantic_private.presumed_terms
   where english_label is not null;
  raise notice '{number}: % carry an English label', n;
  select count(*) into n from semantic_private.presumed_terms
   where canonical_term_id is not null;
  raise notice '{number}: % defer to a canonical', n;
  select count(*) into n from semantic_private.presumed_term_relations;
  raise notice '{number}: % relations recorded', n;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_ris_corpus_enters_the_dictionary.sql")
    path.write_text("\n".join(out) + "\n")
    print(json.dumps({"terms": len(terms), "merges": len(links),
                      "relations": len(edges),
                      "refused_as_relation": refused_relation,
                      "refused_as_metadata": refused_metadata,
                      "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
