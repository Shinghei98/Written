-- 0218 — a skipped row gets a name.
--
-- ## What this is for
--
-- The ISRC route silently skipped all 736 eligible observations for one deploy
-- cycle. Every query it depended on returned the right rows; a `str` was
-- compared against a set of `uuid.UUID`, the membership test was false for every
-- row, and the run reported success having written 9,841 mappings and none of
-- the ones it existed to write.
--
-- **The counter that would have said so existed.** `isrc_not_current` was
-- incremented 736 times and went nowhere, because `worker_job_result_is_safe_v03`
-- allows a fixed set of key names and that was not one of them. A count that is
-- computed and not emitted is the same as no count.
--
-- ## The four that are added, and why not eight
--
-- Every ISRC-bearing observation must now land in exactly one bucket, and the
-- route raises if they do not sum. Seven buckets and a residual is eight
-- numbers; the receipt permits **sixteen keys total** and `recompute_user`
-- already uses ten, so all eight would not fit and the cap is not worth raising
-- for diagnostics.
--
-- So the receipt carries the four that decide whether a run was healthy —
-- `isrc_eligible`, `isrc_mapped`, `isrc_not_current`, `isrc_unaccounted` — and
-- the full breakdown is printed to CloudWatch, where there is no key limit and
-- integers are payload-safe by construction. The arithmetic check does its work
-- regardless of what is emitted: it fails the job, which is louder than any
-- receipt.
--
-- ## An unknown counter already fails loudly, and that is asserted here
--
-- The concern that an unrecognised diagnostic would be *silently discarded* does
-- not hold in this schema, and it is worth pinning rather than assuming.
-- `PostgresJobQueue.succeed` writes the result dict straight into `result`
-- with no filtering, `worker_job_row_is_safe_v03` calls this validator, and the
-- validator's `else return false` refuses the row — so the `update` raises and
-- the job fails. A handler that invents a counter breaks visibly. The assertion
-- at the foot demonstrates it rather than describing it.

begin;

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
    -- 0208. What the overlay's jobs measure.
    'resolved_count', 'ambiguous_count', 'unresolved_count', 'remaining_count',
    'inferred_count', 'secondary_count', 'struck_count',
    -- 0218. The ISRC route's disposition, so a run that maps nothing says so in
    -- the row rather than only in a log. `isrc_unaccounted` must be zero; the
    -- route raises before it can be anything else, and its presence here is what
    -- makes that visible after the fact.
    'isrc_eligible', 'isrc_mapped', 'isrc_not_current', 'isrc_unaccounted'
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
           'quarantined', 'superseded', 'not_found', 'no_op',
           -- 0208. A batched job's third answer.
           'partial'
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
  receipt jsonb;
begin
  -- 1. A real `recompute_user` receipt with the four new counters, at the size
  --    it will actually be: ten existing keys plus four.
  receipt := jsonb_build_object(
    'status', 'succeeded', 'item_count', 390, 'created_count', 0,
    'skipped_count', 0, 'changed', true, 'candidate_count', 0,
    'abstained', false, 'mapping_count', 9841,
    'semantic_run_id', extensions.gen_random_uuid()::text,
    'fitness_snapshot_id', extensions.gen_random_uuid()::text,
    'isrc_eligible', 736, 'isrc_mapped', 731,
    'isrc_not_current', 0, 'isrc_unaccounted', 0);
  if not semantic_private.worker_job_result_is_safe_v03(receipt) then
    raise exception '0218: a real receipt carrying the new counters was refused';
  end if;
  if (select count(*) from jsonb_object_keys(receipt)) > 16 then
    raise exception '0218: the receipt shape already exceeds the sixteen-key limit';
  end if;

  -- 2. **An invented counter is refused, not dropped.** This is the property the
  --    whole migration rests on: a handler that emits a name nobody declared
  --    fails its job rather than losing the number. `succeed()` writes the dict
  --    through unfiltered, so the refusal below is what the running system does.
  if semantic_private.worker_job_result_is_safe_v03(
       jsonb_build_object('status', 'succeeded', 'isrc_mystery_count', 1)) then
    raise exception '0218: an undeclared counter was accepted';
  end if;

  -- 3. And a counter that is not a count.
  if semantic_private.worker_job_result_is_safe_v03(
       jsonb_build_object('status', 'succeeded', 'isrc_eligible', 'lots')) then
    raise exception '0218: a non-integer was accepted as a count';
  end if;

  -- 4. Text still cannot travel, which is what this vocabulary exists for.
  if semantic_private.worker_job_result_is_safe_v03(
       jsonb_build_object('status', 'succeeded', 'mention_text', 'Jay Chou')) then
    raise exception '0218: a receipt carrying text was accepted';
  end if;

  raise notice '0218: four ISRC counters admitted; unknown, mistyped and textual keys refused';
end;
$$;

commit;
