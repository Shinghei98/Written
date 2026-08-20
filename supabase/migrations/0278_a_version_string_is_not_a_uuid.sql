-- 0278 — a version string is not a uuid, and the contract said it was.
--
-- `0262` taught the closed result contract the words two deployed handlers
-- already spoke, and got one of them wrong: it admitted `version` among the
-- **uuid** keys, and `mint_from_kept_requests` returns the ontology version —
-- `0.36.3`. So `worker_json_field_is_valid_v03(payload, 'version', 'uuid')`
-- refused every mint receipt, the succeed-update raised, the invocation died
-- at its boundary, and the lease expired.
--
-- **The mint itself had already committed**, which is why thirteen requests
-- completed while not one `process_mint_requests` job has ever recorded a
-- success. Work landing and bookkeeping dying is the exact shape `0262` was
-- written to fix; it fixed two instances and introduced a third.
--
-- The repair is the handler's, not the vocabulary's: the version leaves the
-- receipt, because `mint_requests.outcome` already records which version each
-- decision landed in and a receipt duplicating the ledger is a second copy
-- that can disagree. So the key comes back out of the contract — it can never
-- be satisfied, and leaving it invites the same mistake.

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
    'fitness_snapshot_id'
    -- `version` was here (0262) and is removed (0278): the value it named is
    -- an ontology version string, which no uuid check can accept.
  ];
  allowed_count_keys constant text[] := array[
    'mapping_count', 'classification_count', 'candidate_count',
    'assertion_count', 'item_count', 'term_candidate_count',
    'created_count', 'updated_count', 'skipped_count', 'quarantined_count',
    'resolved_count', 'ambiguous_count', 'unresolved_count', 'remaining_count',
    'inferred_count', 'secondary_count', 'struck_count',
    'isrc_eligible',
    'isrc_examined', 'isrc_mapped', 'isrc_not_current',
    'isrc_catalog_pending', 'isrc_unaccounted',
    'provisional_minted', 'provisional_count',
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

do $$
begin
  -- The receipt the handler now returns is accepted.
  if not semantic_private.worker_job_result_is_safe_v03(
    '{"processed":true,"minted":1,"linked":0,"refused":0,
      "memories_confirmed":1,"recomputes_bumped":1}'::jsonb) then
    raise exception '0278: the mint receipt is still refused';
  end if;

  -- The one it used to return is refused, in both the shapes it could take —
  -- a version string and, now, a uuid: the key is gone, not retyped.
  if semantic_private.worker_job_result_is_safe_v03(
    '{"processed":true,"minted":1,"version":"0.36.3"}'::jsonb) then
    raise exception '0278: a version string is still admitted';
  end if;
  if semantic_private.worker_job_result_is_safe_v03(
    ('{"processed":true,"version":"a4f9b0f2-0a53-46e4-9b81-9e57d242a856"}')::jsonb) then
    raise exception '0278: the version key is still admitted';
  end if;

  -- And the contract is still closed to everything else.
  if semantic_private.worker_job_result_is_safe_v03(
    '{"status":"succeeded","surprise":1}'::jsonb) then
    raise exception '0278: unknown keys are no longer refused';
  end if;
end;
$$;
