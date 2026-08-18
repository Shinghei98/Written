-- 0248 — the armer waits for an authorized lane, and the model role can log in.
--
-- ## Arming while the lane is off poisons the work
--
-- `0247` wired `arm_extract_mentions` into `arm_candidate_overlay`, which runs on
-- a schedule regardless of mode. With `qwen_overlay = off` the handler declines
-- and the job settles **successfully** as a no-op — and its idempotency key
-- stays. That key is a digest of the outstanding evidence set plus the prompt and
-- grammar versions, so the same work under the same versions can never be armed
-- again. Turning the lane on afterwards would find every account already
-- "processed", permanently, by jobs that did nothing.
--
-- A no-op that consumes the right to try again is worse than an error. Three
-- changes:
--
-- 1. **Arm only in an authorized non-`off` release.** The mode is read from the
--    same place the handler reads it, so the queue cannot disagree with the
--    contract about whether the lane is live.
-- 2. **The mode and release are in the identity.** Work attempted under
--    `evaluation` is not the same work as the same rows under `shadow`, and a key
--    that ignored the difference would let one mode consume the other's turn.
-- 3. **Exclude what is already queued or running**, so a second arming while a
--    job waits does not create a duplicate that will collide on collection.
--
-- ## `semantic_model_worker` could not log in, and a migration is where that ends
--
-- The model-lane credential was provisioned into Secrets Manager naming a role
-- `0239` created `nologin`. Nothing in the repository closed the gap, so the
-- lane held a password for an identity that could not use it.
--
-- **The deterministic lane reads as a counter-example and is the opposite of
-- one.** `0057` also creates `semantic_worker` `nologin`, and that Lambda has
-- been connecting for months — but production answers `rolcanlogin = true` for
-- it (checked 2026-08-18), so somebody granted it by hand and no migration
-- records the change. That is exactly the invisible configuration
-- `aws/worker/stack.yaml` and `tools/verify_worker_deployment.sh` exist to end,
-- and provisioning the second identity the same way would move the hole one role
-- along rather than close it.
--
-- **A standing contract said otherwise and it was amended, not bypassed.**
-- `0239_model_lane_authority_contract` asserted `nologin` — while
-- `aws/worker/model_lane.py` describes the handoff as "two secrets, two
-- connections … never a shared credential and never a `SET ROLE`", a design that
-- cannot work without authentication. The contract forbade what the design
-- requires, so it now asserts the property `nologin` was standing in for — that
-- the role's powers are exactly its enumerated grants — and asserts it more
-- strictly, refusing membership of *any* role rather than of the two named ones.
--
-- So `login` is granted here, and **no password is set here**. A role with
-- `login` and no password authenticates nothing, so this grants a capability
-- rather than an access; the password goes into
-- `written/semantic-model-worker` out of band, which is why
-- `verify_worker_deployment.sh` must prove a **connection** rather than the
-- presence of a secret. The only honest check of a credential is using it.
--
-- **What `login` must not become.** It is a way to authenticate, never a way to
-- acquire the other lane's powers: the role keeps `noinherit`, keeps its
-- enumerated grants, and `0243`'s refusal — that neither lane identity is a
-- member of the other — is asserted again below. A capability added to a role is
-- the moment to re-check the boundary around it, not the moment to assume it
-- held.

-- ---------------------------------------------------------------------------
-- The armer, gated on the lane actually being open.
-- ---------------------------------------------------------------------------

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
  mode text;
  release uuid;
begin
  -- **The database's own authority on whether a lane is open**, not a second
  -- flag beside it. `authorized_model_release` returns the deployed release and
  -- its mode, and returns *nothing* when no non-`off` release is deployed — so
  -- "no row" is exactly "the lane is off", and the queue cannot disagree with
  -- the deployment about whether the model may be called.
  --
  -- Nothing is armed in that state. A job armed now settles as a successful
  -- no-op and keeps its idempotency key, which spends the only chance that work
  -- had of ever being done.
  select a.release_manifest_id, a.model_lane_mode into release, mode
    from semantic_private.authorized_model_release() a;
  if release is null or mode is null or mode = 'off' then
    return 0;
  end if;

  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  select 'extract_mentions', work.user_id,
         jsonb_build_object('user_id', work.user_id,
                            'grammar_version', grammar_version,
                            'prompt_version', prompt_version),
         -- **The mode is in the identity.** The same rows under `evaluation` are
         -- not the same work as under `shadow`, and a key blind to that would let
         -- one mode consume the other's turn.
         'overlay:extract_mentions:' || work.user_id::text || ':'
           || md5(mode || ':' || release::text || ':' || prompt_version
                  || ':' || grammar_version || ':' || work.identity),
         now()
    from (
      select u.user_id,
             string_agg(u.token, ',' order by u.token) as identity
        from (
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
   -- **Not while one is already in flight.** A second arming during a deferral
   -- would queue a duplicate for evidence a running job is about to claim, and
   -- both would then race to record the same logical extraction.
   where not exists (
     select 1 from semantic_private.worker_jobs j
      where j.job_type = 'extract_mentions'
        and j.user_id = work.user_id
        and j.status in ('queued', 'running'))
      on conflict (idempotency_key) do nothing;

  get diagnostics armed = row_count;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_extract_mentions(uuid, text, text)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.arm_extract_mentions(uuid, text, text)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- The model lane can authenticate. It gains nothing else.
-- ---------------------------------------------------------------------------

-- **A capability, not an access.** No password is set, here or in any migration
-- — one committed to git is one published — so this role authenticates nothing
-- until `written/semantic-model-worker` is filled in and the connection is
-- proved by using it.
alter role semantic_model_worker login;

-- ---------------------------------------------------------------------------
-- What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  armed integer;
  can_login boolean;
  inherits boolean;
  crossed integer;
begin
  select rolcanlogin, rolinherit into can_login, inherits from pg_roles
   where rolname = 'semantic_model_worker';
  if not can_login then
    raise exception
      '0248: semantic_model_worker still cannot log in, so the model lane cannot '
      'connect and a credential was provisioned for an identity that cannot use it';
  end if;

  -- **The grant above widened one thing and must not have widened another.**
  -- `noinherit` is what keeps the role's powers exactly its enumerated grants;
  -- an inheriting role picks up whatever it is later made a member of, which is
  -- the quiet way `0243`'s separation stops being true.
  if inherits then
    raise exception
      '0248: semantic_model_worker inherits, so its powers are no longer the '
      'list 0239 and 0241 enumerate';
  end if;

  -- `0243` asserts this at creation; it is asserted again here because the role
  -- just gained a way to authenticate, and a boundary is worth re-reading at
  -- the moment something changed on the other side of it.
  select count(*) into crossed
    from pg_auth_members m
    join pg_roles granted on granted.oid = m.roleid
    join pg_roles member on member.oid = m.member
   where (member.rolname = 'semantic_worker'
          and granted.rolname = 'semantic_model_worker')
      or (member.rolname = 'semantic_model_worker'
          and granted.rolname = 'semantic_worker');
  if crossed <> 0 then
    raise exception
      '0248: a lane identity that can now log in is a member of the other lane';
  end if;

  -- **Off means nothing is armed, exercised rather than described.** No
  -- non-`off` release is deployed in a replayed chain, so a global call must
  -- arm nothing — and this is the one call that is safe to make globally
  -- precisely because the lane is shut.
  if exists (select 1 from semantic_private.authorized_model_release()) then
    raise exception
      '0248: a calling-lane release is deployed in a fresh chain; the off-mode '
      'assertion below would not be testing anything';
  end if;
  armed := semantic_private.arm_extract_mentions();
  if armed <> 0 then
    raise exception
      '0248: % job(s) were armed with the lane off; each would settle as a '
      'successful no-op and keep the key that work needs to run later', armed;
  end if;

  if position('authorized_model_release' in pg_get_functiondef(
       'semantic_private.arm_extract_mentions(uuid, text, text)'::regprocedure)) = 0 then
    raise exception
      '0248: the armer does not consult the deployed release, so it can arm work '
      'that will settle as a no-op and never be armed again';
  end if;
end;
$$;
