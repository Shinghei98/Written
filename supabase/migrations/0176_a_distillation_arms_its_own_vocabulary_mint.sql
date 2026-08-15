-- 0176 — a distillation arms its own vocabulary mint.
--
-- ## What this is for
--
-- `0173` can mint a creator concept from Apple's catalogue, and nothing runs it.
-- A human fetches with `tools/apple_catalog.py` and applies a migration, so a new
-- user's artists stay invisible until somebody does that by hand. This is the
-- trigger half: a distillation arms a job, and the job is what will eventually
-- mint.
--
-- ## The window, and why it is trailing-edge
--
-- Somebody connecting five apps produces five ingestion runs over a couple of
-- minutes, and minting after each one would publish five ontology versions for
-- what is one act. So the job is armed with `available_at = now() + 2 minutes`
-- and **every later finalization pushes that forward**, which is a debounce on
-- the trailing edge: work starts once the person has stopped.
--
-- **Two minutes is when work begins, not a deadline for finishing** (owner,
-- 2026-08-14). The mint itself may take far longer, and because it does, users
-- who fall due while one is running are picked up by the next pass — so batching
-- across users is a consequence of the design rather than something bolted on.
--
-- ## No new column, and the one that was already there
--
-- `worker_jobs.available_at` has existed since `0042`, is `not null default
-- now()`, and is covered by `worker_jobs_claim_idx (available_at, created_at)
-- where status = 'queued'`. `PostgresJobQueue.claim()` filters
-- `available_at <= now()` and orders by it. **Nothing in this repository has ever
-- written it** except the retry backoff in `repository.py`. It is a delayed-start
-- column that was built and never used.
--
-- ## Re-arming is an UPDATE, and it has to be
--
-- `idempotency_key` is globally unique and every enqueue path in the schema uses
-- `on conflict (idempotency_key) do nothing`, so **re-inserting the same key
-- silently discards the new row and cannot refresh a timer** — even when the
-- existing row is already `succeeded` or `dead`. So arming pushes an existing
-- queued row forward and only inserts when there is none.
--
-- That update is safe by inspection of the guard: `worker_jobs_guard_contract_v03`
-- fires `before insert or update of job_type, user_id, payload, idempotency_key,
-- locked_at, locked_by, last_error, result` — `available_at` is not in that list,
-- so pushing it forward revalidates nothing and trips no trigger.
--
-- **The key carries the revision only for uniqueness.** Coalescing is done by the
-- "is one already queued" test, not by the key; the revision is monotonic per
-- user, so a mint armed after an earlier one has finished always gets a fresh
-- key rather than colliding with a spent one.
--
-- ## Fired from a trigger, not from the finalizer
--
-- `finalize_ingestion_run_v031` is three hundred lines and its live definition is
-- in `0048`, not where it was first written. Editing it to add one call would
-- mean reproducing all of it. `bump_user_state_revision` has the same need and
-- solves it with a trigger pair on `ingestion_runs` — after insert when the run
-- is already `succeeded`, and after update of status when it becomes so. This
-- mirrors that pair exactly, including the `old.status is distinct from
-- new.status` guard that stops a no-op update re-arming the window.
--
-- ## Do not apply this before the handler ships
--
-- `SemanticWorker.run_once` fails closed on a job type it has no handler for:
-- it claims the job and marks it `dead` with `no_handler:mint_vocabulary`,
-- terminally. `aws/worker/handler.py` registers `recompute_user` and nothing
-- else. So applying this migration against the current Lambda arms a job every
-- two minutes for the sole purpose of killing it — noise in the queue, a wasted
-- claim on each drain, and a `dead` row that looks like a failure and is not.
--
-- **Apply after the minter is deployed, not before.** The same ordering rule as
-- `0174`, and for the same reason: the code ships in the Lambda zip, and a
-- migration cannot see whether it is there.
--
-- ## No gate on coverage
--
-- Any distillation arms a mint, whether or not the person has unresolved terms
-- (owner, 2026-08-14). A user with nothing new costs one claimed job that finds
-- nothing to do, which is cheaper than a threshold nobody can tune from two
-- accounts.

begin;

-- 1. The job type. A check constraint over `text` rather than an enum, so this
--    is a swap rather than an `alter type` — the pattern `0046` established.
alter table semantic_private.worker_jobs
  drop constraint if exists worker_jobs_job_type_v03_check;

alter table semantic_private.worker_jobs
  add constraint worker_jobs_job_type_v03_check check (job_type in (
    'map_observation', 'recompute_user', 'mine_terms', 'refresh_external_entity',
    'classify_calendar', 'resolve_youtube_channel', 'build_memories',
    'compute_dyad', 'render_bio', 'render_icebreaker', 'derive_fitness_habits',
    'mint_vocabulary'
  ));

-- 2. The payload contract.
--
--    **`refresh_external_entity` was the obvious candidate and does not fit.**
--    Its payload is `{external_entity_id, refresher_version}` — it re-fetches a
--    cache row that already exists, which is what `external_entities.expires_at`
--    is for. It cannot discover entities for a user whose ISRCs have never been
--    looked up, which is the entire job here.
--
--    Reproduced whole because the `case` *is* the registry — there is no
--    registration table — and `worker_job_row_is_safe_v03` names this function by
--    its exact `_v03` signature. Only the `mint_vocabulary` branch is new.
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
    else
      return false;
  end case;
end;
$$;

-- 3. Arming, which is an update first and an insert only if there is nothing to
--    update.
create or replace function semantic_private.arm_vocabulary_mint(
  p_user_id uuid,
  p_delay interval default interval '2 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  rearmed  integer := 0;
  inserted integer := 0;
  revision bigint;
begin
  if p_user_id is null then
    return 0;
  end if;

  -- **Push an existing window forward rather than opening a second one.** This
  -- is the whole debounce: the fifth app connected in two minutes finds the job
  -- armed by the first and moves its start time, so one person's burst produces
  -- one mint.
  update semantic_private.worker_jobs
     set available_at = now() + p_delay
   where job_type = 'mint_vocabulary'
     and user_id = p_user_id
     and status = 'queued';
  get diagnostics rearmed = row_count;
  if rearmed > 0 then
    return 0;
  end if;

  select coalesce(max(s.revision), 0) into revision
    from semantic_private.user_state_versions s
   where s.user_id = p_user_id;

  insert into semantic_private.worker_jobs (
    job_type, user_id, payload, idempotency_key, available_at
  )
  values (
    'mint_vocabulary', p_user_id,
    jsonb_build_object('user_id', p_user_id::text),
    'vocabulary-mint:' || p_user_id::text || ':' || revision::text,
    now() + p_delay
  )
  on conflict (idempotency_key) do nothing;
  get diagnostics inserted = row_count;
  return inserted;
end;
$$;

revoke all on function semantic_private.arm_vocabulary_mint(uuid, interval)
  from public, anon, authenticated;

create or replace function semantic_private.arm_vocabulary_mint_on_ingestion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform semantic_private.arm_vocabulary_mint(new.user_id);
  return null;
end;
$$;

revoke all on function semantic_private.arm_vocabulary_mint_on_ingestion()
  from public, anon, authenticated;

-- The pair mirrors `ingestion_run_{insert,update}_bump_semantic_revision`,
-- including the `old.status is distinct from new.status` guard — without it a
-- no-op update on an already-succeeded run would push the window forward and a
-- burst of them would keep a mint permanently two minutes away.
drop trigger if exists ingestion_run_insert_arms_vocabulary_mint
  on semantic_private.ingestion_runs;
create trigger ingestion_run_insert_arms_vocabulary_mint
  after insert on semantic_private.ingestion_runs
  for each row when (new.status = 'succeeded')
  execute function semantic_private.arm_vocabulary_mint_on_ingestion();

drop trigger if exists ingestion_run_update_arms_vocabulary_mint
  on semantic_private.ingestion_runs;
create trigger ingestion_run_update_arms_vocabulary_mint
  after update of status on semantic_private.ingestion_runs
  for each row when (new.status = 'succeeded' and old.status is distinct from new.status)
  execute function semantic_private.arm_vocabulary_mint_on_ingestion();

do $$
declare
  probe_user uuid;
  job_id     uuid;
  first_due  timestamptz;
  second_due timestamptz;
  armed      integer;
  extra      integer;
begin
  -- **The debounce is proved here, not asserted about.** A window that does not
  -- move is indistinguishable from one that does until somebody arms it twice,
  -- and the whole design rests on the second arming being an update.
  --
  -- Rolled back through a subtransaction so replaying this migration leaves no
  -- job behind. PL/pgSQL variables survive the rollback; rows do not.
  select id into probe_user from auth.users limit 1;
  if probe_user is null then
    raise notice '0176: no account to probe the debounce against, skipping';
    return;
  end if;

  begin
    armed := semantic_private.arm_vocabulary_mint(probe_user, interval '2 minutes');
    select id, available_at into job_id, first_due
      from semantic_private.worker_jobs
     where job_type = 'mint_vocabulary' and user_id = probe_user and status = 'queued';

    extra := semantic_private.arm_vocabulary_mint(probe_user, interval '9 minutes');
    select available_at into second_due
      from semantic_private.worker_jobs where id = job_id;

    if armed <> 1 then
      raise exception '0176: arming did not create a job (got %)', armed;
    end if;
    if extra <> 0 then
      raise exception '0176: arming twice created a second job';
    end if;
    if second_due <= first_due then
      raise exception '0176: re-arming did not push the window forward';
    end if;
    if (select count(*) from semantic_private.worker_jobs
         where job_type = 'mint_vocabulary' and user_id = probe_user) <> 1 then
      raise exception '0176: expected exactly one mint job for the probe user';
    end if;

    raise exception 'rollback_the_probe';
  exception when others then
    if sqlerrm <> 'rollback_the_probe' then
      raise;
    end if;
  end;

  raise notice '0176: debounce proved — one job, window pushed forward, rolled back';
end;
$$;

do $$
begin
  -- The job type is accepted, and an unknown one still is not.
  if not semantic_private.worker_job_payload_is_valid_v03(
       'mint_vocabulary',
       '00000000-0000-0000-0000-000000000001'::uuid,
       jsonb_build_object('user_id', '00000000-0000-0000-0000-000000000001')
     ) then
    raise exception '0176: a valid mint_vocabulary payload was refused';
  end if;

  -- A closed control message: an extra field is refused, and so is a payload
  -- whose user does not match the queue row.
  if semantic_private.worker_job_payload_is_valid_v03(
       'mint_vocabulary',
       '00000000-0000-0000-0000-000000000001'::uuid,
       jsonb_build_object('user_id', '00000000-0000-0000-0000-000000000001',
                          'reason', 'because')
     ) then
    raise exception '0176: an unknown payload field was accepted';
  end if;
  if semantic_private.worker_job_payload_is_valid_v03(
       'mint_vocabulary',
       '00000000-0000-0000-0000-000000000002'::uuid,
       jsonb_build_object('user_id', '00000000-0000-0000-0000-000000000001')
     ) then
    raise exception '0176: a payload naming another user was accepted';
  end if;
  if semantic_private.worker_job_payload_is_valid_v03(
       'mint_vocabulary', null,
       jsonb_build_object('user_id', '00000000-0000-0000-0000-000000000001')
     ) then
    raise exception '0176: a fleet-wide mint_vocabulary row was accepted';
  end if;

  -- And the branches this migration reproduced verbatim still answer.
  if not semantic_private.worker_job_payload_is_valid_v03(
       'refresh_external_entity', null,
       jsonb_build_object(
         'external_entity_id', '00000000-0000-0000-0000-000000000003',
         'refresher_version', '0.1.0')
     ) then
    raise exception '0176: reproducing the validator broke refresh_external_entity';
  end if;
  if semantic_private.worker_job_payload_is_valid_v03(
       'not_a_job_type', null, '{}'::jsonb
     ) then
    raise exception '0176: an unknown job type was accepted';
  end if;

  raise notice '0176: payload contract holds for mint_vocabulary and its neighbours';
end;
$$;

commit;
