-- 0452 — a repair that changes nothing publishes nothing.
--
-- **Why the queue could never drain**: `0451` taught the still-floating
-- count that a non-active parent edge is an adjudication — but it did
-- not teach the batch. The adjudicated concept (Footloose, held by a
-- `rejected` edge) re-entered through the orphan query on every run;
-- the insert skipped it, `attached` came back 0, and the function
-- still created a version, copied the whole ontology forward,
-- published it, and — per `0396` — enqueued the recompute that would
-- call it again. Ten identical versions in forty minutes
-- (0.41.17–0.41.26, every description this function's own), each one
-- re-enqueueing every user, forever. The occasional
-- "still reach no block" raise was two of those runs racing the same
-- version number — a symptom of the loop running at all, not a
-- separate defect.
--
-- The fix applies the adjudication to the batch *before* any version
-- exists. A concept holding a `broader` edge in any status at the
-- published version is not attachable here: an active edge means it is
-- already parented (the insert would skip it), a non-active edge means
-- a curation decision holds it (never re-litigated by a repair pass).
-- What remains is exactly the set the insert would write — and when
-- that set is empty the function returns before creating anything, so
-- a no-op repair publishes no version and asks for no recompute.
--
-- The still-floating raise survives unchanged for the batch that does
-- attach: a parent that reaches no block is still a defect said out
-- loud. Asserted as a transformation, not a precondition — the same
-- function answers identically on an empty database and on production.

begin;

CREATE OR REPLACE FUNCTION semantic_private.attach_kept_concept_parents(p_parents jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_version    text;
  current_version_id uuid;
  next_version       text;
  new_version_id     uuid;
  live_parents       jsonb;
  held_count         integer := 0;
  attached           integer := 0;
  still_floating     integer := 0;
begin
  if p_parents is null or p_parents = '{}'::jsonb then
    return jsonb_build_object('status', 'no_op', 'updated_count', 0);
  end if;

  select version, id into current_version, current_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'attach_kept_concept_parents: no published ontology version';
  end if;

  -- 0452: the adjudication is applied to the batch before any version
  -- exists. An edge standing in ANY status at the published version
  -- takes the concept out of the batch — active means already
  -- parented, non-active means a curation decision holds it. What
  -- remains is exactly what the insert below will write.
  select coalesce(jsonb_object_agg(entry.key, entry.value), '{}'::jsonb)
    into live_parents
    from jsonb_each(p_parents) as entry
   where not exists (
     select 1 from ontology.concept_edges held
      where held.ontology_version_id = current_version_id
        and held.subject_concept_id = (entry.key)::uuid
        and held.predicate_key = 'broader');
  held_count := (select count(*) from jsonb_each(p_parents))
              - (select count(*) from jsonb_each(live_parents));

  -- 0452: a batch that would change nothing creates nothing — no
  -- draft, no publish, and no recompute asked for.
  if live_parents = '{}'::jsonb then
    return jsonb_build_object('status', 'no_op', 'updated_count', 0,
                              'held_or_parented', held_count);
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

  perform ontology.copy_forward_version(current_version_id, new_version_id);

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, (entry.key)::uuid, 'broader', (entry.value #>> '{}')::uuid,
         1.0, 'provider',
         jsonb_build_object('source', '0272_kept_term_parent_backfill'),
         'active'
    from jsonb_each(live_parents) as entry
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
  -- float — counted, reported, and left for the fold machinery. Kept
  -- as belt-and-braces under 0452's filter: for the batch that does
  -- attach, a parent that reaches no block is still said out loud.
  select count(*) into still_floating
    from jsonb_each(live_parents) as entry
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

  return jsonb_build_object('status', 'succeeded', 'updated_count', attached,
                            'held_or_parented', held_count);
end;
$function$;

commit;
