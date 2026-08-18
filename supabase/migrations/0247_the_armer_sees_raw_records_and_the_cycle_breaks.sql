-- 0247 — the armer sees unfiled raw records, so the lane can start at all.
--
-- `0244`'s armer required `source_text_evidence` to exist, and evidence is
-- created only inside a running `extract_mentions` job. **Nothing could ever be
-- first.** An account with two hundred eligible raw records and no evidence
-- armed no job, filed no evidence, and reported converged — which is
-- indistinguishable from an account with nothing to say.
--
-- The armer now recognises both kinds of outstanding work: evidence nothing has
-- asked about, and **eligible raw records nothing has filed evidence for**. The
-- second is what breaks the cycle, and it is also the honest description of the
-- job — `extract_mentions` files evidence and then asks about it, so work
-- exists as soon as there is something to file.
--
-- ## The allowlist is applied before the first arming
--
-- Not only inside the handler. A job armed for an account whose only rows are
-- Spotify would decrypt nothing, ask nothing and settle as a no-op — harmless,
-- but it would also mean the queue carried work whose only possible outcome was
-- refusal, and a queue that does that cannot be read as a list of what is
-- outstanding.
--
-- **The list is duplicated here deliberately and asserted against the code.**
-- `MODEL_INPUT_PROFILES` in `overlay.py` is the one that governs what is sent;
-- this one governs what is armed, and `tools/replay_contracts.sh` compares them
-- so a source added on one side fails rather than drifts.
--
-- ## And something calls it
--
-- `arm_candidate_overlay` already runs on the schedule that arms the rest of the
-- overlay, so this is added there rather than given a second caller. Ingestion
-- finalization enqueues that path already; a bounded drain is not needed on top.

create or replace function semantic_private.model_input_source_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  -- Apple Music, its device library, and podcasts. **Calendar and HealthKit are
  -- licensed and still absent**: calendar titles reach the scorer through the
  -- classifier Lambda and never through this lane, and HealthKit has no text.
  -- YouTube and Spotify are absent because their terms forbid a model call on
  -- their content — III.E.4.h and IV.2.1.a, and IV.2.5 closes the consent route.
  select array['apple_music', 'music_library', 'apple_podcasts', 'podcast'];
$$;

comment on function semantic_private.model_input_source_codes is
  'The sources whose text may reach a model. Mirrors MODEL_INPUT_PROFILES in '
  'overlay.py, which governs what is sent; this governs what is armed, and a '
  'contract subtest compares the two so one cannot drift from the other.';

create or replace function semantic_private.arm_extract_mentions(
  target_user uuid default null,
  grammar_version text default 'semantic_grammar_v3',
  prompt_version text default 'qwen_extractor_v5'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  armed integer := 0;
  allowed text[] := semantic_private.model_input_source_codes();
begin
  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  select 'extract_mentions', work.user_id,
         jsonb_build_object('user_id', work.user_id,
                            'grammar_version', grammar_version,
                            'prompt_version', prompt_version),
         -- **The batch's identity, not its size.** A count repeats: an account
         -- that processes two rows and later gains two more presents the same
         -- number and would collide with the key that batch already used. This
         -- digests the actual outstanding set together with the versions that
         -- decide what would be asked of it, so the key changes exactly when the
         -- work or the question does.
         'overlay:extract_mentions:' || work.user_id::text || ':'
           || md5(prompt_version || ':' || grammar_version || ':' || work.identity),
         now()
    from (
      select u.user_id,
             string_agg(u.token, ',' order by u.token) as identity
        from (
          -- Evidence nothing has asked about.
          select e.user_id, 'e:' || e.id::text as token
            from semantic_private.source_text_evidence e
            join semantic_private.observations o on o.id = e.observation_id
           where e.refresh_status = 'current'
             and o.lifecycle_state = 'active'
             and o.source_code = any(allowed)
             and not exists (
               select 1 from semantic_private.model_invocation_items i
                where i.source_text_evidence_id = e.id)
          union all
          -- **Raw records with no evidence yet.** The half that was missing, and
          -- the reason nothing could ever be first.
          select c.user_id, 'r:' || c.current_observation_id::text as token
            from semantic_private.current_source_items c
            join semantic_private.raw_source_records r
              on r.id = c.current_raw_source_record_id
           where c.current_observation_id is not null
             and r.encrypted_payload is not null
             and c.source_code = any(allowed)
             and not exists (
               select 1 from semantic_private.source_text_evidence e
                where e.observation_id = c.current_observation_id
                  and e.refresh_status <> 'deleted')
        ) as u
       where target_user is null or u.user_id = target_user
       group by u.user_id
    ) as work
      on conflict (idempotency_key) do nothing;

  get diagnostics armed = row_count;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_extract_mentions(uuid, text, text)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.arm_extract_mentions(uuid, text, text)
  to semantic_worker;
revoke all on function semantic_private.model_input_source_codes()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.model_input_source_codes()
  to semantic_worker, semantic_model_worker;

-- ---------------------------------------------------------------------------
-- What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  allowed text[] := semantic_private.model_input_source_codes();
begin
  -- The two that may never be here, asserted rather than trusted to the literal
  -- above staying correct through a later edit.
  if 'spotify' = any(allowed) or 'youtube' = any(allowed) then
    raise exception
      '0247: a source whose terms forbid a model call is on the model-input list';
  end if;
  if array_length(allowed, 1) is null then
    raise exception '0247: the model-input list is empty; nothing could ever arm';
  end if;

  -- **Executed, not merely compiled.** A `create or replace function` proves the
  -- body parses and nothing more — the first version of this armer had six
  -- values for a five-column insert and replayed perfectly, because a replay
  -- creates the function and never calls it. Calling it on an empty database
  -- exercises the whole statement.
  declare armed integer;
  begin
    armed := semantic_private.arm_extract_mentions();
    if armed <> 0 then
      raise exception
        '0247: the armer produced % jobs with nothing to arm for', armed;
    end if;
    armed := semantic_private.arm_extract_mentions(
      '00000000-0000-4000-8000-00000000dead');
    if armed <> 0 then
      raise exception '0247: arming for an unknown account produced % jobs', armed;
    end if;
  end;

  -- The armer must name the list rather than repeating it, or the assertion
  -- above protects a literal nothing consults.
  if position('model_input_source_codes' in
      pg_get_functiondef('semantic_private.arm_extract_mentions(uuid, text, text)'::regprocedure)) = 0 then
    raise exception
      '0247: the armer does not consult model_input_source_codes, so the '
      'licensing list and the arming list can disagree';
  end if;
end;
$$;
