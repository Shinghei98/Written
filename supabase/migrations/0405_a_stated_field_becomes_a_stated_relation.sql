-- 0405 — a stated field becomes a stated relation, no model asked.
--
-- **The owner, 2026-08-26: "build it, no model needed."** Timi's "Brat"
-- drew bare while the evidence said `primary_performer: "Charli xcx"`
-- in so many words — the fact sat in the source's own schema and
-- nothing carried it into the dictionary, because the relation lane
-- only holds what the model states. Keeping a field and inferring one
-- are different acts: this is a keep.
--
-- `promote_field_stated_relations()` reads active observations'
-- structured fields and appends dictionary relations between EXISTING
-- term rows only — a missing end refuses (the projection lane mints
-- artists; this rule never invents an identity):
--
--   - `performed_by`: the row's title-term and album-term each relate
--     to the `primary_performer`-named person/group term.
--   - `composed_by` instead, for the composer field on rows whose
--     stated genres include Classical — the same asymmetry the display
--     rule (0373) already draws.
--
-- Appended `authored` (0398's precedent for rule-derived rows) with the
-- rule named in evidence; idempotent by not-exists, so the worker may
-- call it every run. **No ontology version and no recompute**: dictionary
-- relations are read live by the page's label composer and are
-- non-traversable for scoring (0306), so the backfill below shows up on
-- the next page load and moves no score.
--
-- The worker calls this at the top of `process_mint_requests`
-- (aws/worker/overlay.py), so every future ingest's fields promote on
-- the next run without anyone asking.

begin;

create or replace function semantic_private.promote_field_stated_relations()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  performed integer := 0;
  composed integer := 0;
begin
  with fields as (
    select distinct
      lower(btrim(o.normalized_payload ->> 'title')) as title,
      lower(btrim(coalesce(o.normalized_payload ->> 'album', ''))) as album,
      lower(btrim(o.normalized_payload ->> 'primary_performer')) as performer
    from semantic_private.observations o
    where o.lifecycle_state = 'active'
      and nullif(btrim(o.normalized_payload ->> 'primary_performer'), '') is not null
      and nullif(btrim(o.normalized_payload ->> 'title'), '') is not null
  ),
  pairs as (
    select distinct subject_term.id as subject_id, object_term.id as object_id
    from fields f
    join semantic_private.presumed_terms subject_term
      on subject_term.normalized_label in (f.title, f.album)
     and subject_term.family in ('work', 'music_work', 'album',
                                 'music_recording', 'franchise')
    join semantic_private.presumed_terms object_term
      on object_term.normalized_label = f.performer
     and object_term.family in ('person', 'group')
     and object_term.id <> subject_term.id
  )
  insert into semantic_private.presumed_term_relations
    (subject_term_id, predicate, object_term_id, basis, evidence)
  select p.subject_id, 'performed_by', p.object_id, 'authored',
         jsonb_build_object('rule', '0405 field statement')
    from pairs p
   where not exists (
     select 1 from semantic_private.presumed_term_relations r
      where r.subject_term_id = p.subject_id
        and r.predicate = 'performed_by'
        and r.object_term_id = p.object_id);
  get diagnostics performed = row_count;

  with fields as (
    select distinct
      lower(btrim(o.normalized_payload ->> 'title')) as title,
      lower(btrim(coalesce(o.normalized_payload ->> 'album', ''))) as album,
      lower(btrim(o.normalized_payload ->> 'composer')) as composer
    from semantic_private.observations o
    where o.lifecycle_state = 'active'
      and o.normalized_payload -> 'genres' ? 'Classical'
      and nullif(btrim(o.normalized_payload ->> 'composer'), '') is not null
      and nullif(btrim(o.normalized_payload ->> 'title'), '') is not null
  ),
  pairs as (
    select distinct subject_term.id as subject_id, object_term.id as object_id
    from fields f
    join semantic_private.presumed_terms subject_term
      on subject_term.normalized_label in (f.title, f.album)
     and subject_term.family in ('work', 'music_work', 'album',
                                 'music_recording', 'franchise')
    join semantic_private.presumed_terms object_term
      on object_term.normalized_label = f.composer
     and object_term.family = 'person'
     and object_term.id <> subject_term.id
  )
  insert into semantic_private.presumed_term_relations
    (subject_term_id, predicate, object_term_id, basis, evidence)
  select p.subject_id, 'composed_by', p.object_id, 'authored',
         jsonb_build_object('rule', '0405 field statement')
    from pairs p
   where not exists (
     select 1 from semantic_private.presumed_term_relations r
      where r.subject_term_id = p.subject_id
        and r.predicate = 'composed_by'
        and r.object_term_id = p.object_id);
  get diagnostics composed = row_count;

  return jsonb_build_object('performed_by_added', performed,
                            'composed_by_added', composed);
end;
$function$;

revoke execute on function semantic_private.promote_field_stated_relations()
  from public, anon, authenticated;

-- The backfill: once, now, over everything already in the vault.
do $$
declare receipt jsonb;
begin
  select semantic_private.promote_field_stated_relations() into receipt;
  raise notice '0405 backfill: %', receipt;
end;
$$;

commit;
