-- 0451 — a rejected parent is a decision, not a float.
--
-- **Why every recompute failed**: the kept-parent repair met one
-- concept ("Footloose: The Musical (Original Broadway Cast
-- Recording)") whose assigned parent edge already exists with status
-- `rejected` — a curation decision. The function's insert hit the
-- corpse through `on conflict do nothing`, its active-only guard never
-- saw it, and the still-floating count raised — rolling back the whole
-- mint batch for every user, every run, forever. Two fixes, both to
-- the function:
--
--   * a concept whose assigned edge stands in any non-active status is
--     held by that adjudication — excluded from the raise, left for
--     the fold machinery, never re-litigated by a repair pass;
--   * `on conflict (version) do nothing returning` yields null on
--     collision, and every downstream read would run against version
--     null — the id now resolves either way.

begin;

CREATE OR REPLACE FUNCTION semantic_private.attach_kept_concept_parents(p_parents jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_version text;
  next_version    text;
  new_version_id  uuid;
  attached integer := 0;
  still_floating integer := 0;
begin
  if p_parents is null or p_parents = '{}'::jsonb then
    return jsonb_build_object('status', 'no_op', 'updated_count', 0);
  end if;

  select version into current_version
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'attach_kept_concept_parents: no published ontology version';
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
                 || split_part(current_version, '.', 2) || '.'
                 || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  select gen_random_uuid(), next_version, v.id, 'draft',
         'Kept-term parents, derived from the genre the source states.'
    from ontology.versions v where v.version = current_version
  on conflict (version) do nothing
  returning id into new_version_id;
  -- 0451: `on conflict do nothing returning` yields null when the
  -- version already exists, and every read below would then run
  -- against version null. Resolve the id either way.
  if new_version_id is null then
    select id into new_version_id from ontology.versions
     where version = next_version;
  end if;

  perform ontology.copy_forward_version(
    (select id from ontology.versions where version = current_version),
    new_version_id);

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, (entry.key)::uuid, 'broader', (entry.value #>> '{}')::uuid,
         1.0, 'provider',
         jsonb_build_object('source', '0272_kept_term_parent_backfill'),
         'active'
    from jsonb_each(p_parents) as entry
   where not exists (
     select 1 from ontology.concept_edges held
      where held.ontology_version_id = new_version_id
        and held.subject_concept_id = (entry.key)::uuid
        and held.predicate_key = 'broader'
        and held.status = 'active')
  on conflict do nothing;
  get diagnostics attached = row_count;

  perform ontology.publish_version(new_version_id);

  -- 0451: an edge standing in ANY status is an adjudication, not a
  -- float. Footloose's parent edge sat `rejected` — a curation
  -- decision — and this function collided with the corpse via `on
  -- conflict do nothing` every run, raising and rolling back the whole
  -- batch for every user, forever. A concept whose assigned edge was
  -- rejected is held by that rejection: counted, reported, and left
  -- for the fold machinery — never re-litigated here and never
  -- allowed to hostage the batch.
  select count(*) into still_floating
    from jsonb_each(p_parents) as entry
   where semantic_private.concept_block((entry.key)::uuid, new_version_id) is null
     and not exists (
       select 1 from ontology.concept_edges held
        where held.ontology_version_id = new_version_id
          and held.subject_concept_id = (entry.key)::uuid
          and held.predicate_key = 'broader'
          and held.status <> 'active');
  if still_floating > 0 then
    raise exception
      'attach_kept_concept_parents: % concept(s) still reach no block', still_floating;
  end if;

  -- 0396: the published version asks for the recompute that will read it.
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || attached || ' kept-term parent(s) attached');

  return jsonb_build_object('status', 'succeeded', 'updated_count', attached);
end;
$function$
;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0451: the kept-parent repair stops hostaging the batch');
end;
$$;

commit;
