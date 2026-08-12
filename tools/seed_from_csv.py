#!/usr/bin/env python3
"""Emit a migration from the hand-authored ontology CSVs.

**The CSVs were the source of truth and had quietly stopped being one.**
`semantic/ontology/seed_concepts.csv` seeded ontology 0.1.0 through `0044` and
was never read again: music went in through `tools/music_dictionary.py`, YouTube
topics through `tools/youtube_topics.py`, and the database reached 1,261
concepts while the CSVs still described 45. A file that looks like the authority
and is not is worse than no file, because the next person edits it and nothing
happens.

This makes them live again. The split it settles is worth stating: **the CSVs
hold the hand-authored core — hubs, activities, the things somebody decided —
and generated migrations hold what is read out of a library.** 1,092 creator
concepts do not belong in a file anybody edits by hand, and fourteen sports do
not belong in a generated one.

**Everything is emitted, not just what is new**, and that is deliberate. Every
insert is `on conflict do nothing` and the new version copies the old one
forward first, so re-emitting an existing concept is a no-op. The alternative —
diffing against the published version — needs database credentials in a tool
that otherwise needs none, and would make the output depend on when it was run.

**The limitation that follows, and it is the sharp edge here: this adds, it
never edits.** `on conflict do nothing` means changing an existing row's
`preferred_label` or `inference_policy` in the CSV and regenerating does
*nothing at all* — the copy-forward has already placed the old value, and the
insert declines. No error, no warning, a migration that applies cleanly and
changes nothing. That is this codebase's standing defect wearing a new hat, so:
**to change an existing concept, write a migration that updates it in the new
version.** The CSVs are for concepts that do not exist yet.

Run:

    python3 tools/seed_from_csv.py --from 0.4.0 --to 0.5.0 > supabase/migrations/00NN_name.sql
"""

from __future__ import annotations

import argparse
import csv
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ONTOLOGY = ROOT / "semantic" / "ontology"

COPY_FORWARD = """
insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;

insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id,
       m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
       m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
       m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;
"""


def q(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def rows(name: str) -> list[dict[str, str]]:
    with (ONTOLOGY / name).open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def main(old: str, new: str, description: str) -> None:
    concepts = rows("seed_concepts.csv")
    aliases = rows("seed_aliases.csv")
    relations = rows("seed_relations.csv")

    keys = {c["concept_key"] for c in concepts}

    # **A relation naming a concept the CSVs do not define is a typo, and it is
    # a silent one.** The edge insert joins on `concept_key`, so an unknown key
    # produces no row and no error — the migration applies, reports success, and
    # the edge simply is not there. Same failure `youtube_topics.py` guards
    # against by hand; here it is cheap enough to check for real.
    unknown = {r[k] for r in relations for k in ("subject_key", "object_key")
               if r[k] not in keys}
    if unknown:
        sys.exit("relations reference concepts absent from seed_concepts.csv: "
                 + ", ".join(sorted(unknown)))

    print(f"""-- {description}
--
-- Generated by `tools/seed_from_csv.py --from {old} --to {new}`. Do not
-- hand-edit: change `semantic/ontology/*.csv` and regenerate.
--
-- {len(concepts)} concepts, {len(aliases)} labels, {len(relations)} edges — the
-- whole hand-authored core, not only what is new. Every insert is
-- `on conflict do nothing` and {new} copies {old} forward first, so re-stating
-- an existing concept is a no-op.
--
-- A published ontology version is immutable, so this mints {new} from {old} and
-- publishes last — publishing is also retiring, since only one version may be
-- published at a time.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '{new}', v.id, 'draft', {q(description)}, null
from ontology.versions v where v.version = '{old}'
on conflict (version) do nothing;
{COPY_FORWARD.format(old=old, new=new)}""")

    print("create temporary table seed_concept (concept_key text primary key, "
          "preferred_label text not null, concept_kind text not null, "
          "sensitivity text not null, inference_policy text not null, "
          "status text not null) on commit drop;")
    print("insert into seed_concept values")
    print(",\n".join(
        f"  ({q(c['concept_key'])}, {q(c['preferred_label'])}, {q(c['concept_kind'])}, "
        f"{q(c['sensitivity'])}, {q(c['inference_policy'])}, {q(c['status'])})"
        for c in concepts) + ";\n")

    print("create temporary table seed_label (concept_key text, label text, "
          "normalized_label text, locale text, label_type text) on commit drop;")
    print("insert into seed_label values")
    print(",\n".join(
        f"  ({q(a['concept_key'])}, {q(a['alias'])}, {q(a['alias'].strip().lower())}, "
        f"{q(a['locale'])}, {q(a['alias_type'])})"
        for a in aliases) + ";\n")

    print("create temporary table seed_edge (subject_key text, predicate_key text, "
          "object_key text, confidence double precision, status text) on commit drop;")
    print("insert into seed_edge values")
    print(",\n".join(
        f"  ({q(r['subject_key'])}, {q(r['predicate_key'])}, {q(r['object_key'])}, "
        f"{r['confidence']}, {q(r['status'])})"
        for r in relations) + ";\n")

    print(f"""insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), s.concept_key from seed_concept s
on conflict (concept_key) do nothing;

-- **`inference_policy` comes from the CSV, never from a default here.** Every
-- sport is `review_required`, which is the whole reason the column exists: a
-- fitness activity implies something about somebody's body and a watched match
-- implies far less than it looks like it does. Hardcoding `inferable` in the
-- generator would erase a per-concept decision at the point it is written down.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
select v.id, c.id, s.preferred_label, s.concept_kind, null,
       s.sensitivity, s.inference_policy, s.status, '{{}}'::jsonb
from seed_concept s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '{new}') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '{new}') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, subject.id, e.predicate_key, object.id, e.confidence, 'curated',
       '{{"source": "seed_csv"}}'::jsonb, e.status
from seed_edge e
join ontology.concepts subject on subject.concept_key = e.subject_key
join ontology.concepts object on object.concept_key = e.object_key
cross join (select id from ontology.versions where version = '{new}') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '{old}' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '{new}';

commit;""")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="old", required=True)
    parser.add_argument("--to", dest="new", required=True)
    parser.add_argument("--description", default="Hand-authored ontology core.")
    args = parser.parse_args()
    main(args.old, args.new, args.description)
