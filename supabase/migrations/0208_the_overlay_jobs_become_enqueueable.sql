-- 0208 — the candidate overlay's eight jobs become enqueueable.
--
-- ## Apply this after the Lambda is deployed, not before
--
-- `0176` states the rule and the reason: *"the code ships in the Lambda zip, and
-- a migration cannot see whether it is there."* A `job_type` the database
-- permits and `handler.py`'s dispatch dict does not know is claimed once, found
-- handler-less, and marked `dead` with no retry — so the wrong order does not
-- fail, it silently kills whatever is enqueued in the gap.
--
-- The bundle carrying `aws/worker/overlay.py` was deployed before this ran.
--
-- ## What is being registered
--
-- Eight jobs, seven of which run today. The contract declares
-- `initial_mode: exact_only`, and the specification says what that leaves:
-- *"resolve stable identifiers and exact aliases before any model call."* The
-- exact lane is **resolution**, not extraction — so the pipeline works against
-- the 73,126 mentions the legacy resolver has already mined, with no model and
-- no gateway.
--
-- `extract_mentions` is the model lane by definition; the workbook keys its
-- idempotency on `model_version+prompt_version+grammar_version`. Its handler
-- declines while the contract disables the overlay, which is a complete
-- implementation of what it must do in that state rather than a stub. It is
-- registered now so the day the overlay is enabled is not also the day a
-- migration, a handler and a gateway all ship together.
--
-- ## The `case` is the registry
--
-- `worker_job_payload_is_valid_v03` is reproduced whole with eight branches
-- added, because there is no registration table and `worker_job_row_is_safe_v03`
-- names this function by its exact `_v03` signature. The `else return false` at
-- the foot is the fail-closed default and stays where it is.
--
-- **One branch differs from every other and it is the point.**
-- `aggregate_feedback` is fleet-wide and requires `queue_user_id is null`; every
-- other overlay job requires a queue user *and* that the payload names the same
-- one. A system job that named a user would compute one person's statistics and
-- call them everybody's; a per-user job with a null queue user is one that lost
-- whose it was.
--
-- ## Two receipt vocabularies widen, and both were found by the code failing
--
-- `worker_job_result_is_safe_v03` types `changed` as a boolean and permits nine
-- statuses, none of them `partial`. Resolution is batched — 2,000 mentions per
-- invocation against an account holding 73,126 — so it genuinely has a third
-- answer between "succeeded" and "failed", and a receipt that failed the safety
-- check would fail the *job*, after its work had already committed.
--
-- The seven new count keys are the measurements these jobs exist to produce:
-- how many mentions resolved, how many were ambiguous, how many are left. Each
-- is type-checked as a count, so the widening admits integers and nothing else.

begin;

-- ---------------------------------------------------------------------------
-- 1. The job types.
-- ---------------------------------------------------------------------------

alter table semantic_private.worker_jobs
  drop constraint worker_jobs_job_type_v03_check;

alter table semantic_private.worker_jobs
  add constraint worker_jobs_job_type_v03_check
  check (job_type in (
    'map_observation', 'recompute_user', 'mine_terms', 'refresh_external_entity',
    'classify_calendar', 'resolve_youtube_channel', 'build_memories',
    'compute_dyad', 'render_bio', 'render_icebreaker', 'derive_fitness_habits',
    'mint_vocabulary',
    -- 0208, in pipeline order.
    'extract_mentions', 'resolve_mention', 'build_candidate_overlay',
    'aggregate_term_candidates', 'build_review_items', 'apply_feedback',
    'aggregate_feedback', 'evaluate_release'
  ));

-- ---------------------------------------------------------------------------
-- 2. The payload registry.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.worker_job_payload_is_valid_v03(
  target_job_type text,
  queue_user_id uuid,
  payload jsonb
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  case target_job_type
    when 'map_observation' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'observation_id', 'user_id', 'input_revision', 'semantic_run_id',
          'ontology_version_id', 'resolver_model_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'observation_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'semantic_run_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_model_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'classify_calendar' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'observation_id', 'user_id', 'input_revision',
          'ontology_version_id', 'classifier_model_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'observation_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'classifier_model_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'resolve_youtube_channel' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'youtube_channel_row_id', 'youtube_channel_id',
          'ontology_version_id', 'resolver_model_id', 'resolution_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'youtube_channel_row_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'youtube_channel_id', 'youtube_channel_id')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolution_version', 'version')
        and queue_user_id is null;
    when 'recompute_user' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'input_revision', 'ontology_version_id',
          'resolver_model_id', 'scorer_model_id'
        ], array['embedding_model_id'])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'scorer_model_id', 'uuid')
        and (
          not (payload ? 'embedding_model_id')
          or semantic_private.worker_json_field_is_valid_v03(payload, 'embedding_model_id', 'uuid')
        )
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    -- **The new one, and it carries a user and nothing else.**
    --
    -- A payload naming an ontology version or a revision would be stale between
    -- arming and claiming — the debounce exists precisely so that more
    -- distillations arrive in between, each moving the revision. The job derives
    -- what is unresolved when it runs, which is the only moment the answer is
    -- true.
    when 'mint_vocabulary' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'build_memories' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'input_revision', 'ontology_version_id',
          'builder_model_id', 'presentation_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'builder_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'presentation_version', 'version')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'compute_dyad' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'viewer_user_id', 'subject_user_id', 'viewer_revision',
          'subject_revision', 'ontology_version_id', 'ranker_model_id',
          'run_purpose'
        ], array['data_use_purpose'])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'ranker_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'run_purpose', 'dyad_purpose')
        and (
          not (payload ? 'data_use_purpose')
          or semantic_private.worker_json_field_is_valid_v03(payload, 'data_use_purpose', 'data_use_purpose')
        )
        and payload ->> 'viewer_user_id' <> payload ->> 'subject_user_id'
        and queue_user_id is not null
        and payload ->> 'viewer_user_id' = queue_user_id::text;
    when 'render_bio' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'dyad_run_id', 'viewer_user_id', 'subject_user_id',
          'viewer_revision', 'subject_revision', 'renderer_model_id',
          'presentation_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'dyad_run_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'renderer_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'presentation_version', 'version')
        and payload ->> 'viewer_user_id' <> payload ->> 'subject_user_id'
        and queue_user_id is not null
        and payload ->> 'viewer_user_id' = queue_user_id::text;
    when 'render_icebreaker' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'match_authorization_id', 'dyad_run_id', 'viewer_user_id',
          'subject_user_id', 'viewer_revision', 'subject_revision',
          'renderer_model_id', 'template_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'match_authorization_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'dyad_run_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'viewer_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'subject_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'renderer_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'template_version', 'version')
        and payload ->> 'viewer_user_id' <> payload ->> 'subject_user_id'
        and queue_user_id is not null
        and payload ->> 'viewer_user_id' = queue_user_id::text;
    when 'mine_terms' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'aggregate_snapshot_id', 'base_ontology_version_id',
          'miner_model_id', 'minimum_distinct_users', 'mining_policy_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'aggregate_snapshot_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'base_ontology_version_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'miner_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'minimum_distinct_users', 'privacy_threshold')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'mining_policy_version', 'version')
        and queue_user_id is null;
    when 'refresh_external_entity' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'external_entity_id', 'refresher_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'external_entity_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'refresher_version', 'version')
        and queue_user_id is null;
    when 'derive_fitness_habits' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'input_revision', 'fitness_snapshot_id',
          'builder_model_id', 'policy_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'input_revision', 'revision')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'fitness_snapshot_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'builder_model_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'policy_version', 'fitness_policy')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    -- The candidate overlay. Every one of these is per-user except
    -- `aggregate_feedback`, which is fleet-wide and is the only branch here that
    -- requires `queue_user_id is null` — a system job that named a user would be
    -- computing one person's statistics and calling them everybody's, and a
    -- per-user job with a null queue user is one that lost whose it was.
    when 'extract_mentions' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'grammar_version', 'prompt_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'grammar_version', 'version')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'prompt_version', 'version')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'resolve_mention' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'resolver_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'resolver_version', 'version')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'build_candidate_overlay' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'aggregate_term_candidates' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'build_review_items' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id', 'review_epoch'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and semantic_private.worker_json_field_is_valid_v03(payload, 'review_epoch', 'revision')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'apply_feedback' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'user_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'user_id', 'uuid')
        and queue_user_id is not null
        and payload ->> 'user_id' = queue_user_id::text;
    when 'aggregate_feedback' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'aggregation_version'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'aggregation_version', 'version')
        and queue_user_id is null;
    when 'evaluate_release' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          'release_manifest_id'
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, 'release_manifest_id', 'uuid')
        and queue_user_id is null;
    else
      return false;
  end case;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. What a receipt may say.
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
    -- 0208. What the overlay's jobs measure: resolution outcomes, how much of a
    -- batched pass is left, the tier split, and how many terms were struck.
    'resolved_count', 'ambiguous_count', 'unresolved_count', 'remaining_count',
    'inferred_count', 'secondary_count', 'struck_count'
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
           -- 0208. A batched job's third answer. `resolve_mention` caps one
           -- invocation at 2,000 mentions and the largest account holds 73,126,
           -- so "there is more to do" is a real outcome and not a failure.
           'partial'
         ) then return false; end if;
    else
      return false;
    end if;
  end loop;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The one grant `evaluate_release` needs.
-- ---------------------------------------------------------------------------

-- `0203` gave `semantic_worker` select on the release tables and nothing more,
-- which was right when nothing wrote a gate report. `evaluate_release` is the
-- one gate a *running* Lambda can answer that CI cannot — whether the contract
-- this deployed bundle actually loaded is the one the manifest was recorded
-- against — and it has to write the answer down.
grant update (gate_report) on ontology.release_manifests to semantic_worker;

-- ---------------------------------------------------------------------------
-- Assertions.
-- ---------------------------------------------------------------------------

do $$
declare
  probe_user uuid;
  registered integer;
  refusals integer := 0;
begin
  -- 1. Twenty job types, and the eight new ones present by name.
  select count(*) into registered
    from unnest(array['extract_mentions', 'resolve_mention',
                      'build_candidate_overlay', 'aggregate_term_candidates',
                      'build_review_items', 'apply_feedback',
                      'aggregate_feedback', 'evaluate_release']) as wanted
   where exists (
     select 1 from pg_constraint
      where conname = 'worker_jobs_job_type_v03_check'
        and pg_get_constraintdef(oid) like '%' || wanted || '%');
  if registered <> 8 then
    raise exception '0208: % of 8 overlay job types reached the constraint', registered;
  end if;

  -- 2. **The payload registry, answering both ways.** A validator that only
  --    ever accepted has not been shown to discriminate, and the fail-closed
  --    `else` at its foot is exactly the branch a typo would land in.
  select id into probe_user from auth.users limit 1;
  if probe_user is null then
    raise notice '0208: no account to build a probe payload from';
  else
    if not semantic_private.worker_job_payload_is_valid_v03(
         'resolve_mention', probe_user,
         jsonb_build_object('user_id', probe_user::text,
                            'resolver_version', 'exact-0.1.0')) then
      raise exception '0208: a correct resolve_mention payload was refused';
    end if;

    -- A per-user job may not lose whose it is.
    if semantic_private.worker_job_payload_is_valid_v03(
         'resolve_mention', null,
         jsonb_build_object('user_id', probe_user::text,
                            'resolver_version', 'exact-0.1.0')) then
      raise exception '0208: resolve_mention was accepted with no queue user';
    end if;
    refusals := refusals + 1;

    -- And a fleet-wide job may not claim one.
    if not semantic_private.worker_job_payload_is_valid_v03(
         'aggregate_feedback', null,
         jsonb_build_object('aggregation_version', 'v1')) then
      raise exception '0208: a correct aggregate_feedback payload was refused';
    end if;
    if semantic_private.worker_job_payload_is_valid_v03(
         'aggregate_feedback', probe_user,
         jsonb_build_object('aggregation_version', 'v1')) then
      raise exception '0208: aggregate_feedback was accepted for one user';
    end if;
    refusals := refusals + 1;

    -- An unknown field falls to the closed key check.
    if semantic_private.worker_job_payload_is_valid_v03(
         'build_candidate_overlay', probe_user,
         jsonb_build_object('user_id', probe_user::text, 'limit', 10)) then
      raise exception '0208: an unknown payload field was accepted';
    end if;
    refusals := refusals + 1;

    if refusals <> 3 then
      raise exception '0208: expected three refusals, counted %', refusals;
    end if;
  end if;

  -- 3. Receipts the overlay actually returns.
  if not semantic_private.worker_job_result_is_safe_v03(
       jsonb_build_object('status', 'partial', 'item_count', 2000,
                          'resolved_count', 12, 'ambiguous_count', 3,
                          'unresolved_count', 1985, 'remaining_count', 71126)) then
    raise exception '0208: a real resolve_mention receipt was refused';
  end if;
  if semantic_private.worker_job_result_is_safe_v03(
       jsonb_build_object('status', 'succeeded', 'mention_text', 'Jay Chou')) then
    raise exception '0208: a receipt carrying text was accepted';
  end if;

  -- 4. The grant, asked of the catalog.
  if not has_column_privilege('semantic_worker', 'ontology.release_manifests',
                              'gate_report', 'UPDATE') then
    raise exception '0208: semantic_worker cannot write a gate report';
  end if;
  if has_table_privilege('semantic_worker', 'ontology.release_manifests', 'DELETE') then
    raise exception '0208: semantic_worker may delete release manifests';
  end if;

  raise notice '0208: 8 job types registered, payload registry refused 3 wrong shapes';
end;
$$;

commit;
