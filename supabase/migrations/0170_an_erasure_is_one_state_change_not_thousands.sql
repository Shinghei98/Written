-- 0170 — an erasure is one state change, not two thousand seven hundred.
--
-- ## What `0169` broke, an hour after it fixed something else
--
-- `0169` gave `api.forget_distillation` the step it had been missing: taking
-- the evidence out of scoring, without which retiring the claims was undone by
-- the next run. The step is right. Its cost was not measured, and it made the
-- control fail outright:
--
--   19:12:51  0169 applied.
--   19:14:33  `canceling statement due to statement timeout` — Disconnect all,
--             from the app, on the demo account.
--
-- `authenticated` runs with `statement_timeout = 8s`. The erasure updates every
-- observation the account has — 2,709 on that account — and
-- `observation_lifecycle_bump_semantic_revision` fires **for each row**, each
-- firing an upsert against the single `user_state_versions` row for that user.
-- Two thousand seven hundred sequential updates to one row, plus 2,684 raw
-- records each running `guard_raw_source_record_update`, do not finish in eight
-- seconds.
--
-- **The visible failure is worse than a slow button.** `deleteEverything`
-- committed first, the local state cleared regardless — the plant went back to
-- bare soil — and the vault kept everything. So the person is shown a
-- disconnected account whose terms are all still there, which is the exact
-- shape `0166` was written to end.
--
-- ## The fix is the trigger, not the ceiling
--
-- Raising `statement_timeout` would make this pass on an account of 2,709
-- observations and fail on one of 20,000. The work itself is wrong: an erasure
-- is **one** change to a user's state, and the revision should move once.
--
-- `bump_user_state_revision` already anticipated this exactly. Its own comment:
-- *"A third close would have to appear here too, which is the argument for
-- these being named flags rather than one shared one — a path that forgot to
-- name itself would silently invalidate every score its user has, and that is
-- exactly what happened once."* This is that third path, and it names itself.
--
-- **The revision still moves, and must.** The two existing flags belong to
-- paths that change nothing a scorer reads; this one changes everything it
-- reads. So the per-row bump is suppressed and a single bump is written at the
-- end — same outcome, one row touched instead of thousands.
--
-- **`statement_timeout` is raised as well, and is a backstop rather than the
-- fix.** With the trigger quiet the erasure is two bulk updates and a delete,
-- but somebody with a very large library should not discover a new ceiling by
-- having their erasure half-fail. 60s stays under the API gateway's own limit,
-- so a caller still gets an answer rather than a dropped connection.
--
-- **A `security definer` function setting a GUC affects only itself** — the
-- `set` clause is scoped to the call and restored on exit, so this does not
-- lend a longer timeout to anything else `authenticated` does.

begin;

create or replace function semantic_private.bump_user_state_revision()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  -- **Both authorised closes, for the same reason.** The finalizer bumps the
  -- revision itself and only when something changed; the unpromotable close
  -- changes nothing and must bump nothing. A third close would have to appear
  -- here too, which is the argument for these being named flags rather than one
  -- shared one — a path that forgot to name itself would silently invalidate
  -- every score its user has, and that is exactly what happened once.
  --
  -- **The third has arrived, and it is the opposite case.** `forget_distillation`
  -- moves every observation a user has, and the revision genuinely should move
  -- — once. Letting it fire per row made the erasure exceed `authenticated`'s
  -- eight-second `statement_timeout` at 2,709 observations, which is a small
  -- library. So the flag suppresses the per-row bump and the function writes a
  -- single one itself; what is being skipped here is the repetition, not the
  -- bump.
  if coalesce(
       current_setting('written.finalize_ingestion_v031', true), '0'
     ) = '1'
     or coalesce(
       current_setting('written.close_unpromotable_v031', true), '0'
     ) = '1'
     or coalesce(
       current_setting('written.forget_distillation_v031', true), '0'
     ) = '1' then
    return new;
  end if;
  insert into semantic_private.user_state_versions (user_id, revision)
  values (new.user_id, 1)
  on conflict (user_id) do update
  set revision = semantic_private.user_state_versions.revision + 1,
      updated_at = now();
  return new;
end;
$$;

create or replace function api.forget_distillation()
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
set statement_timeout to '60s'
as $$
declare
  me uuid := auth.uid();
  retired integer := 0;
  excluded_rows integer := 0;
  redacted integer := 0;
begin
  -- **No parameter for whose.** Every function in this schema is scoped to
  -- `auth.uid()`, so a caller cannot act on anybody but themselves.
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;

  -- **Set before the first write and never reset.** `set_config(..., true)` is
  -- transaction-local, so it lifts when this call's transaction ends whether it
  -- commits or rolls back — there is no path that leaves the suppression on for
  -- the next caller, and no need for an exception handler that could swallow a
  -- real failure while restoring it.
  perform set_config('written.forget_distillation_v031', '1', true);

  -- 1. The claims. Inferred only: an `explicit_addition` is what the person
  --    typed in Memories, which is the same fact as a `source = 'user'` row in
  --    the legacy path.
  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where user_id = me
     and assertion_origin = 'inferred'
     and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  -- 2. **The evidence, out of scoring.** `resolve.py` filters
  --    `lifecycle_state = 'active'` and mappings are made per run rather than
  --    reused, so nothing here is ever mapped again — which is what makes the
  --    retirement above durable rather than undone by the next model bump.
  update semantic_private.observations
     set lifecycle_state = 'deleted',
         exclusion_code  = 'user_deleted',
         excluded_at     = now()
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics excluded_rows = row_count;

  -- 3. The captured payloads, every source.
  --    `raw_source_records_payload_location_check` refuses `lifecycle_state =
  --    'deleted'` unless both columns are null, so the state and the redaction
  --    cannot disagree.
  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  -- 4. The vault's own connection rows, for every source.
  delete from semantic_private.source_connections
   where user_id = me;

  -- 5. **The revision, once.** This is the bump the trigger was suppressed
  --    from making 2,709 times. It is not bookkeeping: the scorer's inputs have
  --    all just changed, and `api.list_assertions` withholds an inferred
  --    assertion whose score was computed at an older revision — so a claim
  --    that somehow survives step 1 is still not shown.
  --
  --    Only where the erasure touched something. A second Disconnect all on an
  --    already-empty account should be a no-op, not a revision bump that
  --    invalidates whatever the person has done since.
  if excluded_rows > 0 or redacted > 0 or retired > 0 then
    insert into semantic_private.user_state_versions (user_id, revision)
    values (me, 1)
    on conflict (user_id) do update
    set revision = semantic_private.user_state_versions.revision + 1,
        updated_at = now();
  end if;

  -- **A receipt, because the caller must not have to guess.** An erasure
  -- answering `void` would make "the terms are still there" and "the call never
  -- ran" the same observation from the client's side.
  return jsonb_build_object(
    'assertions_retired', retired,
    'observations_excluded', excluded_rows,
    'records_redacted', redacted
  );
end;
$$;

revoke all on function api.forget_distillation() from public, anon;
grant execute on function api.forget_distillation() to authenticated;

commit;

-- The exercise, in its own transaction so a failure here cannot leave either
-- function half-replaced.

begin;

do $$
declare
  subject uuid;
  refused boolean := false;
  walked boolean := false;
  excluded_rows integer := -1;
  bumps integer := -1;
  revision_before bigint;
  revision_after bigint;
  survivors_active integer := -1;
  active_before integer;
  active_after integer;
begin
  select count(*) into active_before
    from semantic_private.observations where lifecycle_state = 'active';

  -- **The refusal, first.** A migration has no `auth.uid()`, so the function
  -- must refuse rather than act on whatever null resolves to.
  begin
    perform api.forget_distillation();
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0170: forget_distillation acted for a caller with no identity';
  end if;

  select user_id into subject
    from semantic_private.observations
   where lifecycle_state = 'active'
   group by user_id
   order by count(*) desc
   limit 1;

  if subject is null then
    raise notice '0170: no live observations here; the erasure is unexercised';
  else
    select coalesce(revision, 0) into revision_before
      from semantic_private.user_state_versions where user_id = subject;
    revision_before := coalesce(revision_before, 0);

    begin
      perform set_config('written.forget_distillation_v031', '1', true);

      update semantic_private.observations
         set lifecycle_state = 'deleted',
             exclusion_code  = 'user_deleted',
             excluded_at     = now()
       where user_id = subject and lifecycle_state <> 'deleted';
      get diagnostics excluded_rows = row_count;

      select coalesce(revision, 0) into revision_after
        from semantic_private.user_state_versions where user_id = subject;
      revision_after := coalesce(revision_after, 0);
      bumps := revision_after - revision_before;

      select count(*) into survivors_active
        from semantic_private.observations
       where user_id = subject and lifecycle_state = 'active';

      walked := true;
      raise exception '0170 dry run' using errcode = '22000';
    exception when others then
      if not walked then raise; end if;
    end;

    -- **The whole point of this migration, stated as a number.** Before, this
    -- would have been `excluded_rows`; the erasure that timed out moved the
    -- revision 2,709 times.
    if bumps <> 0 then
      raise exception
        '0170: excluding % observations moved the revision % times; the suppression is not working',
        excluded_rows, bumps;
    end if;
    if survivors_active <> 0 then
      raise exception '0170: % observations stayed active through the erasure',
        survivors_active;
    end if;
    raise notice
      '0170: % observations excluded with the revision untouched by the trigger, and rolled back',
      excluded_rows;
  end if;

  -- Proof the rollback held, rather than a comment claiming it did.
  select count(*) into active_after
    from semantic_private.observations where lifecycle_state = 'active';
  if active_after <> active_before then
    raise exception '0170: the exercise did not roll back — active observations % to %',
      active_before, active_after;
  end if;
  raise notice '0170: nothing moved — % active observations, as before', active_after;
end;
$$;

commit;
