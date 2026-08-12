-- 0100 — the twelve runs that were already stuck.
--
-- `0099` stops the leak; this drains what it left. Twelve runs `running` with
-- zero scopes, holding 1,232 rows, the oldest from 2026-08-11 14:38 and three
-- from the afternoon of the 12th.
--
-- **Every one is closed through `close_unpromotable_ingestion_run`**, not by an
-- `update` here. The function refuses a run that has a scope, and writing the
-- same status by hand would bypass the one check that makes this safe — a run
-- with items to promote must go through the finalizer, and a migration that
-- knows better than the guard is how the guard stops meaning anything.
--
-- **The apple_music run holding 1,225 rows loses nothing.** Its rows are the v1
-- payload encoding; every one was re-captured under v2 when the wire form
-- changed, so the content exists twice and only these copies are inert. They
-- keep no observations either way: `guard_observation_ingestion_run` refuses an
-- observation whose run is not `running`, so closing the run means their
-- evidence can never be written — which was already true, since a run left open
-- since before finalization existed was never going to finalize. Closing it
-- makes the state say so.
--
-- Written as a loop rather than one statement so a single refusal names the run
-- it came from, and so the count is reported rather than assumed.

begin;

-- **The guard has to name the second path, rather than the second path
-- impersonating the first.** `guard_ingestion_run_update` refuses any update
-- that sets `succeeded` unless `written.finalize_ingestion_v031` is set — a
-- transaction-local flag `finalize_ingestion_run_v031` raises around its own
-- update, so that only a declared finalization path may close a run. `0099`'s
-- close therefore failed with *"successful ingestion runs must use the atomic
-- v0.3.1 finalizer"*, which is the guard working.
--
-- The cheap fix would be to set that same flag from the new function. It would
-- work and it would make the guard's message a lie: there would be two paths
-- and the schema would still claim one. So the guard gains a second named flag
-- instead. Whoever reads it next sees both authorised closes, and adding a
-- third still requires editing this one function.
create or replace function semantic_private.guard_ingestion_run_update()
returns trigger
language plpgsql
set search_path = ''
as $guard$
declare
  in_finalizer boolean := coalesce(
    current_setting('written.finalize_ingestion_v031', true), '0'
  ) = '1';
  in_close boolean := coalesce(
    current_setting('written.close_unpromotable_v031', true), '0'
  ) = '1';
begin
  if new.user_id is distinct from old.user_id
     or new.source_code is distinct from old.source_code
     or new.connector_version is distinct from old.connector_version
     or new.input_hash is distinct from old.input_hash
     or new.started_at is distinct from old.started_at then
    raise exception 'ingestion run identity is immutable';
  end if;
  if old.status <> 'running' and new is distinct from old then
    raise exception 'terminal ingestion runs are immutable';
  end if;
  -- **`in_close` may not set a revision.** The two paths are not equivalent:
  -- the finalizer advances heads and mints a revision, and the close exists
  -- precisely because there is nothing to advance. Allowing it to write one
  -- would let a run with no scope claim it changed current state.
  if in_close and new.finalization_revision is not null then
    raise exception 'an unpromotable close cannot record a finalization revision';
  end if;
  if not (in_finalizer or in_close) and (
       new.status in ('succeeded', 'superseded')
       or new.finalization_revision is distinct from old.finalization_revision
       or new.finalization_receipt is distinct from old.finalization_receipt
       or new.current_state_policy_version is distinct from old.current_state_policy_version
     ) then
    raise exception 'successful ingestion runs must use the atomic v0.3.1 finalizer';
  end if;
  return new;
end;
$guard$;

-- And the close declares itself, transaction-locally, exactly as the finalizer
-- does. `true` on `set_config` is what scopes it to the transaction: a session
-- setting would leave the flag raised for everything that followed on the same
-- connection, which on a pooled connection means somebody else's.
create or replace function semantic_private.close_unpromotable_ingestion_run(
  target_ingestion_run_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = semantic_private, pg_catalog
as $close$
declare
  run_row semantic_private.ingestion_runs%rowtype;
  scope_count integer;
  row_count integer;
  receipt jsonb;
begin
  select * into run_row
    from semantic_private.ingestion_runs
   where id = target_ingestion_run_id
   for update;
  if not found then
    raise exception 'no such ingestion run %', target_ingestion_run_id;
  end if;
  if run_row.status <> 'running' then
    raise exception 'ingestion run % is already %',
      target_ingestion_run_id, run_row.status;
  end if;

  select count(*) into scope_count
    from semantic_private.ingestion_run_scopes
   where ingestion_run_id = target_ingestion_run_id;
  if scope_count > 0 then
    raise exception
      'ingestion run % has % scope(s) and must be finalized, not closed',
      target_ingestion_run_id, scope_count;
  end if;

  select count(*) into row_count
    from semantic_private.raw_source_records
   where ingestion_run_id = target_ingestion_run_id;

  receipt := jsonb_build_object(
    'ingestion_run_id', target_ingestion_run_id::text,
    'status', 'succeeded',
    'state_changed', false,
    'changed_item_count', 0,
    'captured_row_count', row_count,
    'closed_reason', 'no_promotable_scope',
    'policy_version', 'written-current-state-v1.0.0'
  );

  perform set_config('written.close_unpromotable_v031', '1', true);
  update semantic_private.ingestion_runs
     set status = 'succeeded',
         finished_at = now(),
         finalization_receipt = receipt,
         current_state_policy_version = 'written-current-state-v1.0.0'
   where id = target_ingestion_run_id;
  perform set_config('written.close_unpromotable_v031', '0', true);

  return receipt;
end
$close$;

revoke all on function semantic_private.close_unpromotable_ingestion_run(uuid)
  from public;

do $$
declare
  target record;
  closed integer := 0;
  rows_closed integer := 0;
begin
  for target in
    select i.id,
           i.source_code,
           (select count(*) from semantic_private.raw_source_records r
             where r.ingestion_run_id = i.id) as row_count
      from semantic_private.ingestion_runs i
     where i.status = 'running'
       and not exists (
         select 1 from semantic_private.ingestion_run_scopes s
          where s.ingestion_run_id = i.id
       )
     order by i.started_at
  loop
    perform semantic_private.close_unpromotable_ingestion_run(target.id);
    closed := closed + 1;
    rows_closed := rows_closed + target.row_count;
  end loop;

  raise notice 'closed % unpromotable run(s) holding % row(s)', closed, rows_closed;
end
$$;

do $$
declare
  still_open integer;
  with_scopes integer;
begin
  -- **The two halves of "nothing was left behind and nothing was trampled".**
  -- Anything still `running` after this must have a scope, which means it is a
  -- genuine in-flight or abandoned run rather than an unpromotable one — and
  -- that is precisely the population an age-based reaper can now judge.
  select count(*) into still_open
    from semantic_private.ingestion_runs i
   where i.status = 'running'
     and not exists (
       select 1 from semantic_private.ingestion_run_scopes s
        where s.ingestion_run_id = i.id
     );
  if still_open <> 0 then
    raise exception '% unpromotable run(s) are still open', still_open;
  end if;

  -- No run that had a scope was closed by this migration: every `succeeded` run
  -- with scopes must carry a finalization receipt from the finalizer, which
  -- records a revision. A run closed by the wrong path would have the
  -- `no_promotable_scope` reason and a scope at the same time.
  select count(*) into with_scopes
    from semantic_private.ingestion_runs i
   where i.finalization_receipt ->> 'closed_reason' = 'no_promotable_scope'
     and exists (
       select 1 from semantic_private.ingestion_run_scopes s
        where s.ingestion_run_id = i.id
     );
  if with_scopes <> 0 then
    raise exception '% run(s) with scopes were closed as unpromotable', with_scopes;
  end if;
end
$$;

commit;
