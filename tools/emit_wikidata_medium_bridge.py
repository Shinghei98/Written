#!/usr/bin/env python3
"""The catalogue states the medium: a migration from Wikidata's slices.

0463's shape, widened (2026-09-08). The slices come from
`tools/wikidata_work_types.py` (the query names the class, never a user's
string); the intersection with the vocabulary happens here, on the laptop,
and the migration carries literal rows. Three rules, each a refusal:

  * **A work still untyped takes the medium** — `other`, `creative_work` or
    none. A work the v7 corpus already calls a franchise keeps it: the
    owner ruled Persona 5 a franchise though Wikidata's class for it is
    video game, and a franchise spans the media it is made of.
  * **A creator is never retyped by name.** The first draft tried, for
    Loki and Lucifer, and the dry run named FIFTY FIFTY, Irene and Oh My
    Girl as films and series: a person's name is a title's name too often.
    Counted, never written.
  * **Ambiguity refuses.** A name both a film and a song, a series and a
    game, stamps nothing; anime outranks game and series (0463's rule);
    a concept whose own labels disagree stamps nothing.

    WRITTEN_DATABASE_URL=... python3 tools/emit_wikidata_medium_bridge.py \\
        out/work_types.json <n>
"""
from __future__ import annotations

import collections
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "semantic" / "src"))
from written_ontology.normalize import normalize_text  # noqa: E402

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
MEDIUM = {"film": "movie", "anime_film": "anime", "tv_series": "tv_series",
          "anime_tv": "anime", "song": "song", "single": "song",
          "album": "album", "video_game": "game"}
WATCHABLE = {"movie", "tv_series", "anime", "game"}


def resolve(families: list[str]) -> str | None:
    media = {MEDIUM[f] for f in families if f in MEDIUM}
    if "anime" in media and media <= {"anime", "game", "tv_series", "movie"}:
        return "anime"
    if len(media) == 1:
        return next(iter(media))
    return None


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def main() -> int:
    payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    number = sys.argv[2]
    names = payload["names"]

    import psycopg
    with psycopg.connect(os.environ["WRITTEN_DATABASE_URL"]) as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                with v as (select id from ontology.versions where status = 'published')
                select c.concept_key, r.concept_kind, r.metadata ->> 'work_type',
                       array_remove(array_agg(distinct l.label), null) || array[r.preferred_label],
                       exists (select 1 from semantic_private.presumed_terms t
                                where t.promoted_concept_id = c.id and t.family = 'person'
                                  and t.person_subtype is not null) as categorised_person,
                       exists (select 1 from ontology.concept_edges e, v
                                where e.ontology_version_id = v.id and e.status = 'active'
                                  and e.object_concept_id = c.id
                                  and e.predicate_key in ('performed_by', 'composed_by', 'member_of_group')) as performs
                  from ontology.concept_revisions r
                  join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
                  join v on r.ontology_version_id = v.id
                  left join ontology.concept_labels l
                    on l.concept_id = c.id and l.ontology_version_id = v.id and l.status = 'active'
                 where r.status = 'active'
                   and ((r.concept_kind = 'work'
                         and coalesce(r.metadata ->> 'work_type', 'other') in ('other', 'creative_work'))
                        or r.concept_kind = 'creator')
                 group by c.id, c.concept_key, r.concept_kind, r.metadata, r.preferred_label""")
            concepts = cursor.fetchall()

    counts = collections.Counter()
    rows = []
    for key, kind, work_type, labels, categorised, performs in concepts:
        answers = set()
        for label in labels:
            entry = names.get(normalize_text(label))
            if entry:
                medium = resolve(entry["families"])
                answers.add(medium)
        answers.discard(None)
        if not answers:
            counts["no_catalogue_answer"] += 1
            continue
        if len(answers) > 1:
            counts["labels_disagree"] += 1
            continue
        medium = next(iter(answers))
        if kind == "work":
            rows.append((key, "work", medium))
            counts[f"work->{medium}"] += 1
        else:
            # **A creator is never retyped by name (measured 2026-09-08).** The
            # first draft retyped a creator with no category and nothing
            # performing it, and the dry run named FIFTY FIFTY, Irene, IVY and
            # Oh My Girl as films and series: a person's name is a title's
            # name too often, and a missing category is not evidence of a
            # missing person. Counted, never written.
            counts["creator_name_is_a_title"] += 1

    out = [f"""-- {number} — the source states the medium, again, and a title is not a person.
--
-- Wikidata's instance-of slices ({', '.join(s['family'] for s in payload['slices'])}),
-- fetched by class on 2026-09-08 and intersected with the vocabulary on the
-- laptop (0198's egress rule). Three rules, each a refusal — a work still
-- untyped takes the medium; a franchise the v7 corpus named keeps it (the
-- owner: Persona 5 is a franchise though its class is video game); a
-- creator is
-- never retyped by name (a person's name is a title's name too often);
-- ambiguity stamps nothing. Counts: {dict(counts.most_common())}.
--
-- The concept keys keep their historical prefix: a key is identity, not
-- vocabulary. A retyped creator's assertions stand; the readers judge them
-- by the new kind on the next recompute, which this enqueues.
begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  stamped         integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '{number}: no published version; nothing to stamp';
    return;
  end if;

  create temporary table _media (concept_key text primary key, new_kind text, work_type text) on commit drop;
  insert into _media (concept_key, new_kind, work_type) values"""]
    out.append(",\n".join(f"    ({quote(k)}, {quote(kind)}, {quote(m)})" for k, kind, m in sorted(rows)) + ";")
    out.append(f"""
  if not exists (
    select 1 from _media m join ontology.concepts c on c.concept_key = m.concept_key
    join ontology.concept_revisions r on r.concept_id = c.id and r.ontology_version_id = old_version_id and r.status = 'active'
    where r.concept_kind <> m.new_kind or r.metadata ->> 'work_type' is distinct from m.work_type)
  then
    raise notice '{number}: every medium already stands; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The source states the medium, again, and a title is not a person.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_revisions r
     set concept_kind = m.new_kind,
         metadata = coalesce(r.metadata, '{{}}'::jsonb)
                    || jsonb_build_object('work_type', m.work_type,
                                          'work_type_source', 'wikidata_p31',
                                          'medium_bridge', '{number}')
                    || case when r.concept_kind <> m.new_kind
                            then jsonb_build_object('kind_before', r.concept_kind, 'resorted_by', '{number}')
                            else '{{}}'::jsonb end
    from _media m
    join ontology.concepts c on c.concept_key = m.concept_key
   where r.concept_id = c.id and r.ontology_version_id = new_version_id and r.status = 'active';
  get diagnostics stamped = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || stamped || ' medium(s) stamped from Wikidata; titles are not persons');
  raise notice '{number}: % published — % stamped', next_version, stamped;
end $$;

commit;
""")
    path = REPOSITORY / "supabase" / "migrations" / f"{number}_the_source_states_the_medium_again.sql"
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(json.dumps({"rows": len(rows), "counts": dict(counts.most_common()), "migration": str(path)}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
