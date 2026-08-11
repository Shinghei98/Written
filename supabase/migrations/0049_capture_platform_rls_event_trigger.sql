-- 0049 — capture the one piece of production that no migration created.
--
-- Found by comparing the live project against a schema replayed from these
-- files: 126 `public` columns identical across 17 tables, and 117 objects
-- against 116. The single difference was `public.rls_auto_enable()` and its
-- event trigger `ensure_rls`, which enable row-level security automatically on
-- any table created in `public`.
--
-- **It came from the Supabase dashboard, not from this repository.** That is
-- the whole reason to write it down. A schema that is partly in migrations and
-- partly in somebody's console is a schema nobody can rebuild, and the gap is
-- invisible precisely because production behaves *better* than a replay: create
-- a table in `public` there and RLS switches itself on, do the same locally and
-- it does not. The divergence only shows up as a missing policy on a table that
-- looked fine in testing.
--
-- Nothing here changes production, where both objects already exist. It makes a
-- from-empty replay match, which is what the upgrade proof depends on.
--
-- **This takes the number that was pencilled in for the server projections.**
-- The contract requires never *reusing* a number, not keeping them contiguous,
-- and it says so; projections and cutover shift to `0050` and `0051`. Writing
-- this now is the better trade, because it is real and they are not yet.

begin;

-- Reproduced from the live definition rather than written afresh, so a replay
-- produces the same function rather than a plausible one. `search_path` is
-- pinned to `pg_catalog` and the body is unchanged.
create or replace function public.rls_auto_enable()
returns event_trigger
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  cmd record;
begin
  for cmd in
    select *
    from pg_event_trigger_ddl_commands()
    where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      and object_type in ('table', 'partitioned table')
  loop
     if cmd.schema_name is not null
        and cmd.schema_name in ('public')
        and cmd.schema_name not in ('pg_catalog', 'information_schema')
        and cmd.schema_name not like 'pg_toast%'
        and cmd.schema_name not like 'pg_temp%' then
      begin
        execute format('alter table if exists %s enable row level security', cmd.object_identity);
        raise log 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      exception
        when others then
          raise log 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      end;
     else
        raise log 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)',
          cmd.object_identity, cmd.schema_name;
     end if;
  end loop;
end;
$function$;

-- `create event trigger` has no `if not exists`, so it is guarded. Dropping and
-- recreating would work too and is worse: between the two statements a table
-- created in `public` would slip through with RLS off, and this file has to be
-- replay-safe.
do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls
      on ddl_command_end
      execute function public.rls_auto_enable();
  end if;
end;
$$;

comment on function public.rls_auto_enable() is
  'Supabase platform feature, captured into migrations by 0049 after a schema '
  'comparison found it in production and in no file. Enables RLS on any new '
  'table in `public`. Its enforced list is `public` alone, so it does not '
  'reach `semantic_private`, `ontology` or `api` — those carry their own '
  'explicit RLS and grants.';

-- Note for whoever audits the security-definer surface: this function is
-- reachable at `/rest/v1/rpc/rls_auto_enable` by `anon` and `authenticated`,
-- because PostgreSQL grants `execute` to `public` by default. It is one of nine
-- such functions in this schema and calling it outside an event-trigger context
-- errors rather than doing anything, but the whole set deserves a pass of its
-- own. Deliberately not fixed here: this migration exists to make the schema
-- reproducible, and bundling a privilege change into it would mean one commit
-- doing two unrelated things.

commit;
