-- 0099 — a run that promoted nothing is finished, not running.
--
-- **`running` has meant three different things and one of them leaks.**
-- Measured 2026-08-12: 12 runs `running`, holding 1,232 rows, and **every one
-- has zero scopes**. They are three populations:
--
--   8  `user` source runs        every `user` data type is `notAnAction`
--   3  runs that stored nothing  every row was a duplicate
--   1  apple_music, 1,225 rows   the v1 payload run, before the projection worked
--
-- The first two are not accidents and not history: a scope is
-- `(source, data_type, action)` with `action_type not null`, so **a run whose
-- rows carry no action can never have one**. Every `user` distillation has
-- produced a permanent zombie since `0056`, and will produce one on every future
-- distillation. Three appeared today.
--
-- **`0056` was right and incomplete.** Finalization shares the insert's
-- transaction, so a finalizer that refuses a no-scope run rolled the capture
-- back with it — production once went from seven runs to seven and stored
-- nothing. Its fix was to finalize only when a scope exists. But *"do not
-- finalize"* became *"leave it open forever"*, and that is the leak.
--
-- **The third outcome, and why not the other two.** `failed` would be a lie:
-- capture succeeded and there was nothing to promote, which is a real and
-- ordinary result. `finalize_ingestion_run_v031` cannot be used — it refuses a
-- run with no scope manifest, by contract, and that refusal is correct because
-- it is about to advance heads and mint a revision on the strength of a
-- manifest that is not there. So this is a separate, narrower close: it writes
-- a receipt, sets `succeeded`, and touches nothing else.
--
-- The status check already permits exactly this shape —
-- `status in ('succeeded','superseded')` requires `finalization_receipt` and
-- the policy version, and leaves `finalization_revision` free to be null. A run
-- that changed no current state has no revision to record, which is the
-- difference the column exists to express.
--
-- **And an age-based reaper could not have done this.** "Finished with nothing
-- to promote" and "abandoned mid-distillation" look identical from outside —
-- both are `running` with no terminal state — so a sweeper keyed on age would
-- have to guess. Closing the first kind at the moment it is known makes
-- anything still `running` after hours genuinely abandoned, which is what gives
-- `fail_ingestion_run_v031` its first honest caller. It has existed since
-- `0047` with none.

begin;

create or replace function semantic_private.close_unpromotable_ingestion_run(
  target_ingestion_run_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = semantic_private, pg_catalog
as $$
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

  -- **Refused when a scope exists, and that is the whole safety property.**
  -- A run with a scope has items to promote and heads to advance, and closing
  -- it here would silently discard them — a far worse outcome than the leak
  -- this fixes. `finalize_ingestion_run_v031` is the only path for those.
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

  -- `state_changed` false and `changed_item_count` zero are the honest reading
  -- and match what the finalizer writes when nothing moved. `captured_row_count`
  -- is the one field this receipt adds: it is the difference between a run that
  -- captured rows nobody can promote and a run that captured nothing at all,
  -- and both are legitimate.
  receipt := jsonb_build_object(
    'ingestion_run_id', target_ingestion_run_id::text,
    'status', 'succeeded',
    'state_changed', false,
    'changed_item_count', 0,
    'captured_row_count', row_count,
    'closed_reason', 'no_promotable_scope',
    'policy_version', 'written-current-state-v1.0.0'
  );

  update semantic_private.ingestion_runs
     set status = 'succeeded',
         finished_at = now(),
         finalization_receipt = receipt,
         current_state_policy_version = 'written-current-state-v1.0.0'
   where id = target_ingestion_run_id;

  return receipt;
end
$$;

revoke all on function semantic_private.close_unpromotable_ingestion_run(uuid)
  from public;

-- **Patched from the live definition rather than restated.** Two drafts failed
-- here first, and both failures are the same defect this project keeps meeting.
--
-- The first wrote a stub body and dropped it, which would have removed ingestion
-- entirely. The second extracted `0056`'s body from its own migration file — and
-- that body takes **eleven** arguments while the deployed one takes twelve,
-- because `0060` and `0062` added to it afterwards. `create or replace` would
-- have made an *overload*: a second eleven-argument function nobody calls,
-- applying cleanly, changing nothing, and leaking exactly as before. That is
-- `0064`'s trap, and it is the third time this repository has walked into it.
--
-- So this reads `pg_get_functiondef`, checks the anchor is there and the call is
-- not, replaces six lines, and executes the result. It is unusual and it is the
-- only form that cannot silently target a signature that has moved. If the
-- anchor ever changes, this fails loudly instead of quietly overloading.

do $patch$
declare
  definition text;
  anchor constant text :=
'    if scopes_on_run > 0 then
      receipt := semantic_private.finalize_ingestion_run_v031(p_ingestion_run_id);
      finalized := true;
    end if;';
  replacement constant text :=
'    if scopes_on_run > 0 then
      receipt := semantic_private.finalize_ingestion_run_v031(p_ingestion_run_id);
      finalized := true;
    else
      receipt := semantic_private.close_unpromotable_ingestion_run(p_ingestion_run_id);
      finalized := true;
    end if;';
  found integer;
begin
  select count(*) into found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'ingest_source_records_v031';
  if found <> 1 then
    raise exception
      'expected exactly one ingest_source_records_v031, found % — an overload '
      'already exists and must be resolved before patching', found;
  end if;

  select pg_get_functiondef(p.oid) into definition
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'ingest_source_records_v031';

  if position(anchor in definition) = 0 then
    raise exception 'the finalization branch is not where this migration expects it';
  end if;
  if position('close_unpromotable_ingestion_run' in definition) > 0 then
    raise exception 'already patched';
  end if;

  execute replace(definition, anchor, replacement);
end
$patch$;

do $$
declare
  found integer;
begin
  -- Still exactly one, and it now calls the close path. A patch that produced
  -- an overload would pass a "does any function call it" test and fail this one.
  select count(*) into found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'ingest_source_records_v031';
  if found <> 1 then
    raise exception 'patching produced % copies of the function', found;
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'semantic_private'
       and p.proname = 'ingest_source_records_v031'
       and pg_get_functiondef(p.oid) like '%close_unpromotable_ingestion_run%'
  ) then
    raise exception 'the ingest function does not call the close path';
  end if;
end
$$;

commit;
