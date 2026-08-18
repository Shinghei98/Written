-- 0241 — one call, one transaction, and the status is derived.
--
-- `0236` left two outcome vocabularies and said so in its header rather than
-- hiding it: `model_invocations.status` had eight values, `model_invocation_items.outcome`
-- has fourteen, and they did not line up — `abstained` against
-- `semantic_abstention`, `length_truncated` against `output_overflow`, and nine
-- outcomes the call-level column could not express. It was left because nothing
-- wrote either column and reconciling would have been choosing between two
-- guesses.
--
-- The guess is no longer needed. The item is the grain a retry, an erasure and a
-- mode boundary are answered at, so the call-level word is not a second fact —
-- it is a summary, and a summary that can disagree with what it summarises is
-- worse than no summary at all. **`status` is dropped and derived.**
--
-- ## The migration refuses rather than assumes
--
-- Dropping a column is not reversible by re-running the chain, so it asks the
-- database rather than trusting this comment: if `model_invocations` holds any
-- row, the migration raises. Nothing has ever written one — the table has been
-- empty since `0203` created it and repo-wide nothing referenced it until `0236`
-- — but *"nothing writes it"* is a claim about code and the check is about data.
--
-- ## A call and its items are one write
--
-- `record_model_invocation` is the only way in. It derives `batch_items` from
-- the item array, indexes the rows `0 … n-1` by array position, and refuses an
-- array whose length disagrees with the number of items the request asked for.
-- That last check is what makes **`missing_item` an outcome rather than an
-- absence**: a model that answered two of three does not produce two rows and a
-- gap, it produces three rows one of which says `missing_item`. A gap is
-- indistinguishable from a crash mid-write; an outcome is evidence.
--
-- Contiguity is by construction — the index comes from `with ordinality`, not
-- from the caller — so there is no ordering the caller can supply that produces
-- a hole.
--
-- ## And the model role loses its table grants
--
-- `0239` gave `semantic_model_worker` insert on both tables because there was
-- nothing else to give it. There is now: it may execute this function and
-- nothing more, so a partial write is not something it can express. The function
-- is `security definer` for exactly that reason — the privilege lives in the
-- code that upholds the invariant rather than in the role that calls it.

-- ---------------------------------------------------------------------------
-- 1. Refuse rather than assume.
-- ---------------------------------------------------------------------------

do $$
declare
  rows_present integer;
begin
  select count(*) into rows_present from semantic_private.model_invocations;
  if rows_present > 0 then
    raise exception
      '0241: model_invocations holds % rows; dropping status would lose a fact nothing has re-derived. Reconcile them into item outcomes first.',
      rows_present;
  end if;
end;
$$;

alter table semantic_private.model_invocations drop column if exists status;

-- ---------------------------------------------------------------------------
-- 2. The summary is derived from what it summarises.
-- ---------------------------------------------------------------------------

create or replace view semantic_private.model_invocation_summary
with (security_invoker = on) as
select v.id as invocation_id,
       v.user_id,
       v.model_lane_mode,
       v.release_manifest_id,
       v.batch_items,
       count(i.id) as items_recorded,
       count(*) filter (where i.outcome = 'succeeded') as succeeded,
       count(*) filter (where i.outcome = 'semantic_abstention') as abstained,
       count(*) filter (where i.outcome not in ('succeeded', 'semantic_abstention'))
         as failed,
       sum(i.mention_count) as mentions,
       -- **One word, and it is a reading rather than a record.** Every item
       -- succeeded, or none did, or some did; there is no fourth answer and no
       -- column that can disagree with the rows.
       case
         when count(i.id) = 0 then 'no_items'
         when count(*) filter (where i.outcome = 'succeeded') = count(i.id)
           then 'all_succeeded'
         when count(*) filter (where i.outcome = 'succeeded') = 0
           then 'none_succeeded'
         else 'partial'
       end as derived_status,
       v.created_at
  from semantic_private.model_invocations v
  left join semantic_private.model_invocation_items i on i.invocation_id = v.id
 group by v.id, v.user_id, v.model_lane_mode, v.release_manifest_id,
          v.batch_items, v.created_at;

comment on view semantic_private.model_invocation_summary is
  'The call-level word, derived. `status` was a second vocabulary that could '
  'disagree with the item outcomes it purported to summarise; this cannot.';

grant select on semantic_private.model_invocation_summary to semantic_worker;
grant select on semantic_private.model_invocation_summary to semantic_model_worker;

-- ---------------------------------------------------------------------------
-- 3. One call, one write.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.record_model_invocation(
  p_requested_items integer,
  p_items jsonb,
  p_input_hash text,
  p_model_id text,
  p_model_revision text,
  p_prompt_version text,
  p_grammar_version text,
  p_output_schema_hash text,
  p_user_id uuid default null,
  p_output_hash text default null,
  p_contract_hash text default null,
  p_input_tokens integer default null,
  p_output_tokens integer default null,
  p_latency_ms integer default null,
  p_finish_reason text default null,
  p_validation_error_code text default null,
  p_gateway_image_digest text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  supplied integer;
  invocation uuid;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'the item array is required, even when every item failed';
  end if;
  supplied := jsonb_array_length(p_items);

  if p_requested_items < 1 then
    raise exception 'a call must request at least one item';
  end if;

  -- **This is what makes `missing_item` an outcome rather than an absence.** A
  -- model that answered two of three does not produce two rows and a gap; it
  -- produces three rows, one of which says so. A gap is indistinguishable from
  -- a crash mid-write.
  if supplied <> p_requested_items then
    raise exception
      'the request asked for % items and % were recorded; an unanswered item is an outcome, not a missing row',
      p_requested_items, supplied;
  end if;

  -- `batch_items` is derived, never passed. `release_manifest_id` and
  -- `model_lane_mode` are supplied as placeholders and overwritten by
  -- `derive_invocation_lane`, which is where the deployment decides.
  insert into semantic_private.model_invocations
    (user_id, input_hash, output_hash, model_id, model_revision, prompt_version,
     grammar_version, output_schema_hash, contract_hash, batch_items,
     input_tokens, output_tokens, latency_ms, finish_reason,
     validation_error_code, gateway_image_digest,
     release_manifest_id, model_lane_mode)
  select p_user_id, p_input_hash, p_output_hash, p_model_id, p_model_revision,
         p_prompt_version, p_grammar_version, p_output_schema_hash,
         p_contract_hash, supplied, p_input_tokens, p_output_tokens,
         p_latency_ms, p_finish_reason, p_validation_error_code,
         p_gateway_image_digest, a.release_manifest_id, a.model_lane_mode
    from semantic_private.authorized_model_release() a
  returning id into invocation;

  -- Contiguity by construction: the index is the array position, so there is no
  -- ordering a caller can supply that leaves a hole.
  insert into semantic_private.model_invocation_items
    (invocation_id, item_index, user_id, observation_id,
     source_text_evidence_id, source_revision, logical_extraction_key, attempt,
     parent_item_id, outcome, mention_count, estimated_output_tokens,
     actual_output_tokens, input_fingerprint, output_fingerprint,
     fingerprint_key_version)
  select invocation,
         (ordinality - 1)::integer,
         nullif(item ->> 'user_id', '')::uuid,
         nullif(item ->> 'observation_id', '')::uuid,
         nullif(item ->> 'source_text_evidence_id', '')::uuid,
         item ->> 'source_revision',
         item ->> 'logical_extraction_key',
         coalesce((item ->> 'attempt')::integer, 1),
         nullif(item ->> 'parent_item_id', '')::uuid,
         item ->> 'outcome',
         coalesce((item ->> 'mention_count')::integer, 0),
         (item ->> 'estimated_output_tokens')::integer,
         (item ->> 'actual_output_tokens')::integer,
         decode(nullif(item ->> 'input_fingerprint', ''), 'hex'),
         decode(nullif(item ->> 'output_fingerprint', ''), 'hex'),
         item ->> 'fingerprint_key_version'
    from jsonb_array_elements(p_items) with ordinality as t(item, ordinality);

  return invocation;
end;
$$;

comment on function semantic_private.record_model_invocation is
  'The only way to record a model call. Derives batch_items and item_index from '
  'the supplied array, refuses an array that does not answer every requested '
  'item, and writes the call and its items in one statement pair inside one '
  'transaction.';

-- ---------------------------------------------------------------------------
-- 4. The model role may call it and may not go round it.
-- ---------------------------------------------------------------------------

revoke insert on semantic_private.model_invocations from semantic_model_worker;
revoke insert on semantic_private.model_invocation_items from semantic_model_worker;

revoke all on function semantic_private.record_model_invocation(
  integer, jsonb, text, text, text, text, text, text, uuid, text, text,
  integer, integer, integer, text, text, text) from public, anon, authenticated,
  semantic_ingestor, semantic_worker;
grant execute on function semantic_private.record_model_invocation(
  integer, jsonb, text, text, text, text, text, text, uuid, text, text,
  integer, integer, integer, text, text, text) to semantic_model_worker;

-- ---------------------------------------------------------------------------
-- 5. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  select count(*) into n
    from information_schema.columns
   where table_schema = 'semantic_private' and table_name = 'model_invocations'
     and column_name = 'status';
  if n <> 0 then
    raise exception '0241: model_invocations.status is still present';
  end if;

  if has_table_privilege('semantic_model_worker',
                         'semantic_private.model_invocations', 'INSERT')
     or has_table_privilege('semantic_model_worker',
                            'semantic_private.model_invocation_items', 'INSERT') then
    raise exception
      '0241: the model role can still write a call one table at a time';
  end if;

  if not has_function_privilege('semantic_model_worker',
        'semantic_private.record_model_invocation(integer, jsonb, text, text, text, text, text, text, uuid, text, text, integer, integer, integer, text, text, text)',
        'EXECUTE') then
    raise exception '0241: the model role cannot record a call at all';
  end if;

  -- The deterministic lane must not acquire the capability by the back door.
  if has_function_privilege('semantic_worker',
        'semantic_private.record_model_invocation(integer, jsonb, text, text, text, text, text, text, uuid, text, text, integer, integer, integer, text, text, text)',
        'EXECUTE') then
    raise exception '0241: semantic_worker can record a model call';
  end if;
end;
$$;
