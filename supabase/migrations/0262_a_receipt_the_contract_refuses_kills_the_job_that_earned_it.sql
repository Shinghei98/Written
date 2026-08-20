-- 0262 — the closed result contract learns the words two deployed handlers
-- already speak.
--
-- `resolve_mention` has returned `provisional_minted` and `provisional_count`
-- since 0255 put the provisional fallback inside the job, and
-- `worker_job_result_is_safe_v03` (0219) does not know either key — so every
-- succeed UPDATE was refused by `guard_worker_job_contract_v03`, the Lambda
-- invocation died at its boundary, the lease expired, and after five attempts
-- the job was marked dead: eight dead `resolve_mention` jobs between 04:45Z
-- and 08:02Z on 2026-08-20, one fresh corpse per armer cycle, for both real
-- accounts. The resolution work itself committed on the handler's own
-- connection every time — only the bookkeeping died, which is why provisionals
-- kept appearing while the queue reported a crash-loop. The recurring defect
-- in its purest queue-shaped form: a call that can fail (the succeed UPDATE),
-- a result nobody reads (the trigger's refusal, swallowed by the lease), and
-- the symptom surfacing somewhere else (lease_expired_after_max_attempts,
-- which says nothing about a vocabulary).
--
-- `process_mint_requests` (0258/0260) has the same disease latent: it returns
-- `processed` plus `mint_from_kept_requests()`'s receipt — `minted`, `linked`,
-- `refused`, `memories_confirmed`, `recomputes_bumped`, `version` — none of
-- which the contract admits. Undetected because no keep exists yet; the first
-- one is the golden Gate D moment, and its job trail would have died exactly
-- then.
--
-- Same doctrine as 0218/0219's isrc_* keys: the contract validates what
-- deployed code actually writes, deliberately and by name. The handlers do
-- not move; the vocabulary does. Both directions are asserted below.

create or replace function semantic_private.worker_job_result_is_safe_v03(result_payload jsonb)
returns boolean
language plpgsql
immutable
set search_path to ''
as $function$
declare
  item record;
  item_count integer := 0;
  allowed_id_keys constant text[] := array[
    'mapped', 'output_id', 'observation_mapping_id',
    'calendar_classification_id', 'youtube_channel_resolution_id',
    'semantic_run_id', 'memories_snapshot_id', 'dyad_run_id',
    'bio_variant_id', 'icebreaker_frame_id', 'external_entity_id',
    'fitness_snapshot_id',
    -- 0262. `mint_from_kept_requests()` reports which ontology version now
    -- carries the kept vocabulary; the receipt calls it `version` and the
    -- receipt is what the deployed handler returns.
    'version'
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
    'isrc_catalog_pending', 'isrc_unaccounted',
    -- 0262. The provisional fallback runs inside resolve_mention (0255) and
    -- its receipt distinguishes identities minted this pass from mentions
    -- provisioned onto them — a duplicate provisions without minting.
    'provisional_minted', 'provisional_count',
    -- 0262. The mint processor's receipt (0258/0260): kept requests minted as
    -- new global concepts, linked to existing ones, refused on revalidation,
    -- Memories confirmed from keeps, and recompute jobs bumped.
    'minted', 'linked', 'refused', 'memories_confirmed', 'recomputes_bumped'
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
    elsif item.key in ('abstained', 'changed', 'processed') then
      -- `processed` is 0262: the mint processor has said it since 0258.
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
$function$;

-- Both directions, over the exact shapes the two deployed handlers return —
-- a predicate is not believed until it has been seen answering both ways.
do $$
begin
  -- resolve_mention's receipt, verbatim shape from overlay.py line ~1058.
  if not semantic_private.worker_job_result_is_safe_v03(
    '{"status":"partial","item_count":40,"resolved_count":3,
      "ambiguous_count":0,"unresolved_count":37,"provisional_minted":5,
      "provisional_count":12,"remaining_count":120}'::jsonb
  ) then
    raise exception '0262: resolve_mention receipt still refused';
  end if;

  -- process_mint_requests' receipt: {"processed": true, **mint_from_kept_requests()}.
  if not semantic_private.worker_job_result_is_safe_v03(
    ('{"processed":true,"minted":1,"linked":0,"refused":0,'
     || '"memories_confirmed":1,"recomputes_bumped":1,'
     || '"version":"a4f9b0f2-0a53-46e4-9b81-9e57d242a856"}')::jsonb
  ) then
    raise exception '0262: process_mint_requests receipt still refused';
  end if;

  -- The contract stays closed: an unknown key is still refused, and so is a
  -- non-uuid under the new id key and a non-boolean under processed.
  if semantic_private.worker_job_result_is_safe_v03(
    '{"status":"succeeded","surprise":1}'::jsonb
  ) then
    raise exception '0262: unknown keys are no longer refused';
  end if;
  if semantic_private.worker_job_result_is_safe_v03(
    '{"version":"not-a-uuid"}'::jsonb
  ) then
    raise exception '0262: version accepts a non-uuid';
  end if;
  if semantic_private.worker_job_result_is_safe_v03(
    '{"processed":"yes"}'::jsonb
  ) then
    raise exception '0262: processed accepts a non-boolean';
  end if;
end;
$$;
