-- 0217 — resolver 0.11.1: the route 0.11.0 described.
--
-- ## Why a second version so soon
--
-- `0215` published resolver `0.11.0` and recorded, in `parameters` where a later
-- reader looks, that an observation carrying an ISRC is mapped to the recording
-- that ISRC identifies. Three runs then completed under that version and wrote
-- **zero** `provider_id` mappings.
--
-- Two defects, neither of which raised:
--
--   * `semantic_worker` held no `select` on `ontology.external_concept_links`,
--     the table the route joins through. That one surfaced immediately as
--     `42501` — the per-handler diagnostic shipped hours earlier, and it named
--     the table. `0216` granted it.
--   * The currency guard compared `observation.id`, a string, against a set of
--     `uuid.UUID` objects returned by psycopg. `str in {UUID, …}` is false for
--     every row, so all 736 eligible observations were skipped as "not current"
--     — by the guard added that morning to stop *one* row failing the batch.
--     Nothing raised. Every query it depends on returned exactly the right rows.
--
-- **So the runs recorded under `0.11.0` state something untrue.** The version
-- describes a route that did not run, which is the precise condition this
-- project's rule exists for: *a model version that lags its code makes
-- `semantic_runs` state something untrue.* The lag here is the other way round —
-- the version ran ahead of working code — and the remedy is the same. A new
-- version is what forces the fleet to be recomputed against behaviour that
-- actually happens.
--
-- Retiring `0.11.0` rather than editing it. Its runs keep pointing at it, and
-- what they point at now says why they are empty.

begin;

-- **Insert first, retire second, and inherit from whichever version is latest
-- rather than naming one.** The first version of this retired every active
-- resolver and then selected its parameters `from ... where version = '0.11.0'`
-- — so on a database where `0215` did not apply, the select matched nothing, the
-- insert wrote nothing, and the migration left the system with *no* active
-- resolver at all. Retiring before knowing a successor exists is how a
-- precondition failure becomes an outage.
insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select extensions.gen_random_uuid(), 'ontology_first_resolver', '0.11.1', 'resolver', null,
       old.parameters || jsonb_build_object(
         'isrc_route_correction',
         'Resolver 0.11.0 described the ISRC route and did not perform it. Two '
         || 'reasons, neither of which raised: semantic_worker could not read '
         || 'ontology.external_concept_links, which the route joins through '
         || '(granted by 0216); and the currency guard compared a string '
         || 'observation id against a set of uuid.UUID objects, so every '
         || 'eligible observation was skipped as not-current. Runs recorded '
         || 'under 0.11.0 wrote no provider_id mapping and describe a route that '
         || 'did not execute. 0.11.1 is the same route with both fixed.'
       ),
       'active'
  from (
    select * from ontology.model_versions
     where model_key = 'ontology_first_resolver'
     order by string_to_array(version, '.')::integer[] desc
     limit 1
  ) old
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       status = 'active';

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver'
   and status = 'active'
   and version <> '0.11.1';

do $$
declare
  actives   integer;
  enqueued  integer;
  reachable integer;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception '0217: expected one active resolver, found %', actives;
  end if;

  -- **The grant `0216` added, asked of the catalog here too.** This migration
  -- exists because the route could not read that table; publishing another
  -- version without checking would repeat the whole exercise.
  if not has_table_privilege('semantic_worker', 'ontology.external_concept_links', 'SELECT') then
    raise exception '0217: the worker still cannot read the links the route joins through';
  end if;

  select count(*) into reachable
    from ontology.external_concept_links x
    join ontology.external_entities e on e.id = x.external_entity_id
    join ontology.versions v on v.id = x.ontology_version_id and v.status = 'published'
    join ontology.concepts c on c.id = x.concept_id
   where c.concept_key like 'recording:isrc_%' and x.status = 'active'
     and e.entity_kind = 'song';
  -- Same treatment as `0215`: recordings exist where a catalogue does, and a
  -- replay from empty has none. The rule is conditional on the input.
  if reachable = 0 and exists (
       select 1 from ontology.external_entities
        where provider = 'apple_music_catalog' and entity_kind = 'song'
          and raw_payload ? 'name') then
    raise exception '0217: catalogued songs exist and no linked recording does';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.11.1: the ISRC route 0.11.0 described but did not run'
         ) into enqueued;

  raise notice '0217: % recording(s) reachable, % recompute job(s) enqueued',
    reachable, enqueued;
end;
$$;

commit;
