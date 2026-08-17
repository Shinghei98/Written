-- 0219 — the catalogue drains itself.
--
-- ## The coupling
--
-- 953 ISRCs are waiting for a catalogue answer, and the only thing that arms the
-- mint is `arm_vocabulary_mint_on_ingestion` — a trigger on `ingestion_runs`. So
-- "the remaining ISRCs will arrive over the next two or three distillations" was
-- literally true: the drain advances only when somebody opens the app and
-- distils. Work that nobody is waiting for should not require a person to start
-- it, and a queue that only moves when a user acts is a queue that stalls the
-- moment users stop acting — which for a pre-launch product is most of the time.
--
-- `overlay-arm` already establishes the shape: a five-minute schedule that
-- enqueues only where there is work and is free to call when there is none.
-- This is the same, at a slower cadence because each pass costs Apple requests
-- rather than only database time.
--
-- **It does not change what the mint does**, only what wakes it. The debounce,
-- the batch cap, the completeness test and the refusal to mint from an empty
-- catalogue are all unchanged.
--
-- ## And a name that had become wrong
--
-- The ISRC route counts every observation it examines as `isrc_eligible`, and
-- 540 of that account's 2,264 are policy-ineligible — Spotify `playlist_item`
-- and Apple `recommendation`, both weighted 0.000 and both refused on purpose.
-- A denominator that contains the rows it excludes is a denominator that
-- overstates coverage: 731 of 2,264 reads as 32% when the honest figure against
-- policy-eligible rows is **731 of 1,724, or 42%**.
--
-- So `isrc_eligible` becomes `isrc_examined` — what the route looked at — and
-- `isrc_catalog_pending` is admitted beside it, because "no catalogue answer
-- yet" and "catalogued and deliberately not minted" are different facts and only
-- the first is temporary. Recording minting has stopped, so the second is now
-- the normal resting state rather than a shortfall, and a counter that conflated
-- them would report a permanent policy decision as an unfinished job forever.

begin;

-- ---------------------------------------------------------------------------
-- 1. The schedule.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.arm_catalogue_drain()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  pending integer;
  armed integer := 0;
  subject uuid;
begin
  -- Only where an ISRC on a live, policy-eligible observation has no complete
  -- catalogue answer. `name` and `albumName` are the two keys the completeness
  -- test reads, and asking the same question here keeps this from arming a job
  -- that would find nothing to do.
  select count(distinct o.normalized_payload ->> 'isrc') into pending
    from semantic_private.observations o
   where o.lifecycle_state = 'active'
     and o.action_weight > 0
     and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
     and not exists (
       select 1 from ontology.external_entities e
        where e.provider = 'apple_music_catalog'
          and e.entity_kind = 'song'
          and e.external_id = o.normalized_payload ->> 'isrc'
          and e.raw_payload ? 'name'
          and e.raw_payload ? 'albumName');

  if pending = 0 then
    return 0;
  end if;

  -- One account at a time and only when nothing is already queued. The mint
  -- reads across the users it is given and the drain is capped per job, so a
  -- single armed job per pass is what keeps Apple requests to a trickle.
  select o.user_id into subject
    from semantic_private.observations o
   where o.lifecycle_state = 'active'
     and o.action_weight > 0
     and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
     and not exists (
       select 1 from ontology.external_entities e
        where e.provider = 'apple_music_catalog' and e.entity_kind = 'song'
          and e.external_id = o.normalized_payload ->> 'isrc'
          and e.raw_payload ? 'name' and e.raw_payload ? 'albumName')
     and not exists (
       select 1 from semantic_private.worker_jobs j
        where j.job_type = 'mint_vocabulary'
          and j.user_id = o.user_id
          and j.status in ('queued', 'running'))
   limit 1;

  if subject is null then
    return 0;
  end if;

  perform semantic_private.arm_vocabulary_mint(subject);
  armed := 1;
  raise notice 'arm_catalogue_drain: % ISRC(s) pending, armed one mint', pending;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_catalogue_drain()
  from public, anon, authenticated, semantic_ingestor, semantic_worker;

select cron.schedule(
  'catalogue-drain',
  '*/10 * * * *',
  $$select semantic_private.arm_catalogue_drain()$$
);

-- ---------------------------------------------------------------------------
-- 2. The counter that overstated its denominator.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.worker_job_result_is_safe_v03(result_payload jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item record;
  item_count integer := 0;
  allowed_id_keys constant text[] := array[
    'mapped', 'output_id', 'observation_mapping_id',
    'calendar_classification_id', 'youtube_channel_resolution_id',
    'semantic_run_id', 'memories_snapshot_id', 'dyad_run_id',
    'bio_variant_id', 'icebreaker_frame_id', 'external_entity_id',
    'fitness_snapshot_id'
  ];
  allowed_count_keys constant text[] := array[
    'mapping_count', 'classification_count', 'candidate_count',
    'assertion_count', 'item_count', 'term_candidate_count',
    'created_count', 'updated_count', 'skipped_count', 'quarantined_count',
    'resolved_count', 'ambiguous_count', 'unresolved_count', 'remaining_count',
    'inferred_count', 'secondary_count', 'struck_count',
    -- 0218, amended by 0219. `isrc_eligible` is retained so a receipt written
    -- by a bundle deployed before this one still validates — the row is durable
    -- and a rename that invalidated history would fail old jobs on retry.
    'isrc_eligible',
    -- What the route examined, which is not the same as what policy admitted:
    -- 540 of one account's 2,264 are refused before the route sees them.
    'isrc_examined', 'isrc_mapped', 'isrc_not_current',
    -- Waiting for a catalogue answer, as distinct from catalogued and
    -- deliberately not minted. Only the first is temporary.
    'isrc_catalog_pending', 'isrc_unaccounted'
  ];
begin
  if result_payload is null
     or jsonb_typeof(result_payload) <> 'object'
     or octet_length(result_payload::text) > 2048 then
    return false;
  end if;
  for item in select key, value from jsonb_each(result_payload) loop
    item_count := item_count + 1;
    if item_count > 16 then return false; end if;
    if item.key = any (allowed_id_keys) then
      if not semantic_private.worker_json_field_is_valid_v03(
        result_payload, item.key, 'uuid'
      ) then return false; end if;
    elsif item.key = any (allowed_count_keys) then
      if not semantic_private.worker_json_field_is_valid_v03(
        result_payload, item.key, 'count'
      ) then return false; end if;
    elsif item.key in ('abstained', 'changed') then
      if jsonb_typeof(item.value) <> 'boolean' then return false; end if;
    elsif item.key in ('status', 'outcome') then
      if jsonb_typeof(item.value) <> 'string'
         or item.value #>> '{}' not in (
           'succeeded', 'created', 'updated', 'unchanged', 'abstained',
           'quarantined', 'superseded', 'not_found', 'no_op', 'partial'
         ) then return false; end if;
    else
      return false;
    end if;
  end loop;
  return true;
end;
$$;

do $$
declare
  drained integer;
begin
  if not exists (select 1 from cron.job where jobname = 'catalogue-drain') then
    raise exception '0219: the catalogue drain was not scheduled';
  end if;

  -- **Calling it must be free when there is nothing to do**, which is what lets
  -- it sit on a ten-minute schedule.
  select semantic_private.arm_catalogue_drain() into drained;
  select semantic_private.arm_catalogue_drain() into drained;
  if drained <> 0 then
    raise exception '0219: a second drain armed % more job(s)', drained;
  end if;

  -- A receipt in the new shape, at the size it will really be.
  if not semantic_private.worker_job_result_is_safe_v03(jsonb_build_object(
       'status', 'succeeded', 'item_count', 390, 'created_count', 0,
       'skipped_count', 0, 'changed', true, 'candidate_count', 0,
       'abstained', false, 'mapping_count', 9841,
       'semantic_run_id', extensions.gen_random_uuid()::text,
       'fitness_snapshot_id', extensions.gen_random_uuid()::text,
       'isrc_examined', 2264, 'isrc_mapped', 731,
       'isrc_catalog_pending', 953, 'isrc_unaccounted', 0)) then
    raise exception '0219: a receipt in the new shape was refused';
  end if;

  -- And the old one still validates, because durable rows outlive renames.
  if not semantic_private.worker_job_result_is_safe_v03(jsonb_build_object(
       'status', 'succeeded', 'isrc_eligible', 2264)) then
    raise exception '0219: a receipt written before the rename was refused';
  end if;

  raise notice '0219: catalogue-drain scheduled; examined and catalog_pending admitted';
end;
$$;

commit;
