-- 0396 — a published version asks for its recompute.
--
-- **The standing rule: anything that publishes an ontology version ends
-- with `enqueue_recompute_on_analysis_change`** — ingestion is the only
-- other thing that enqueues, and it cannot see a vocabulary change.
-- `mint_from_kept_requests` honours it; its repair half,
-- `attach_kept_concept_parents`, does not: it publishes the version that
-- carries the repaired parents and tells nobody, so the fix sits invisible
-- until the *next* unrelated run happens to score at the new version. By
-- hand that is "run the pipeline twice"; with the queue armers scheduled
-- it would be a repair that waits for a coincidence. One `perform` closes
-- both.
--
-- Everything else is the function's standing text, verbatim.

begin;

create or replace function semantic_private.attach_kept_concept_parents(p_parents jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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

  select count(*) into still_floating
    from jsonb_each(p_parents) as entry
   where semantic_private.concept_block((entry.key)::uuid, new_version_id) is null;
  if still_floating > 0 then
    raise exception
      'attach_kept_concept_parents: % concept(s) still reach no block', still_floating;
  end if;

  -- 0396: the published version asks for the recompute that will read it.
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || attached || ' kept-term parent(s) attached');

  return jsonb_build_object('status', 'succeeded', 'updated_count', attached);
end;
$function$;

commit;
