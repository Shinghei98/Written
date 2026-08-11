-- 0057 — an identity for the worker: reads the vault, writes evidence, and
-- nothing else.
--
-- The mirror of `0052`, and deliberately *not* its twin. The ingestion identity
-- can call exactly one function and read nothing, because the thing exposed to
-- the internet should not be able to read anything back. The worker is the
-- other half of that split: it holds `kms:Decrypt` in AWS, it runs on a
-- schedule rather than on a request, and reading broadly is its whole job.
--
-- **Narrowed by table grants, not by policies.** RLS in this project is keyed on
-- `auth.uid()`, which a batch processor with no JWT can never satisfy — so
-- policies for this role would have to be `using (true)` and would add a second
-- mechanism without removing the first, since the table grants are still what
-- decides. `semantic_worker` gets `bypassrls` and an enumerated grant list
-- instead, which keeps `semantic_private` free of policies entirely: the
-- posture stays "RLS on, no policy anywhere, and every role that reaches these
-- tables is named here".
--
-- `postgres` holds both `bypassrls` and `createrole`, so it can confer the
-- former; a role cannot be granted an attribute its creator lacks.
--
-- **It is still much narrower than `service_role`**, which also bypasses RLS
-- and can read every table in the database. This one can read eight, write two,
-- and touch nothing in `public` or in the app's own `private` schema. The
-- assertion at the foot enumerates that rather than trusting the grants above.
--
-- Password set out of band, like `0052`: a secret in a migration is a secret in
-- git. Created `nologin` with none, so this migration on its own grants nobody
-- anything.
--
-- Ships no product behaviour.

begin;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'semantic_worker') then
    create role semantic_worker nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema semantic_private to semantic_worker;
grant usage on schema ontology to semantic_worker;

-- **Reads.** The vault and everything needed to make sense of a row: which run
-- it came from, which scope, which key version wrapped it, and what the source
-- is worth. `user_encryption_keys` is the one that matters — without the
-- wrapped DEK there is nothing to ask KMS about, and this is the only role
-- other than `service_role` that may see it.
grant select on
  semantic_private.raw_source_records,
  semantic_private.user_encryption_keys,
  semantic_private.ingestion_runs,
  semantic_private.ingestion_run_scopes,
  semantic_private.ingestion_run_items,
  semantic_private.current_source_items,
  semantic_private.source_state_heads,
  semantic_private.sources
to semantic_worker;

-- **Writes.** The queue it drains, and the evidence it produces. Nothing else:
-- assertions, scores, exposures and every product surface are downstream of a
-- separate decision and are not this role's to make.
grant select, update on semantic_private.worker_jobs to semantic_worker;
grant select, insert on semantic_private.observations to semantic_worker;

-- Stated as executable revokes rather than left as absences, so a later
-- `grant ... on all tables in schema` — the trap `0048`, `0050` and `0052` all
-- record — does not widen this role by accident.
revoke all on schema private from semantic_worker;
revoke all on all tables in schema ontology from semantic_worker;

-- `public` is not in that list for the reason `0052` records: usage there
-- belongs to the `PUBLIC` pseudo-role and cannot be revoked from one named
-- role. Schema usage grants nothing without a table privilege, and the
-- assertion below reads the table count rather than the schema flag.

comment on role semantic_worker is
  'Reads the encrypted vault and writes observations. Holds kms:Decrypt in AWS; '
  'bypasses RLS because it has no JWT to satisfy it, and is narrowed by an '
  'enumerated grant list instead. Password set out of band.';

-- ---------------------------------------------------------------------------

-- The claim, checked rather than asserted — and checked the same way `0052`
-- checks its own, because "narrower than service_role" is the entire argument
-- for this role existing.
do $$
declare
  readable text;
  writable text;
  reachable_public integer;
begin
  select pg_catalog.string_agg(c.relname, ', ' order by c.relname)
    into readable
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'semantic_private'
     and c.relkind in ('r', 'p')
     and pg_catalog.has_table_privilege('semantic_worker', c.oid, 'select');

  if readable is distinct from
     'current_source_items, ingestion_run_items, ingestion_run_scopes, '
     || 'ingestion_runs, observations, raw_source_records, source_state_heads, '
     || 'sources, user_encryption_keys, worker_jobs' then
    raise exception 'semantic_worker reads an unexpected set of tables: %', readable;
  end if;

  select pg_catalog.string_agg(c.relname, ', ' order by c.relname)
    into writable
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'semantic_private'
     and c.relkind in ('r', 'p')
     and (pg_catalog.has_table_privilege('semantic_worker', c.oid, 'insert')
       or pg_catalog.has_table_privilege('semantic_worker', c.oid, 'update')
       or pg_catalog.has_table_privilege('semantic_worker', c.oid, 'delete'));

  if writable is distinct from 'observations, worker_jobs' then
    raise exception 'semantic_worker writes an unexpected set of tables: %', writable;
  end if;

  select pg_catalog.count(*)
    into reachable_public
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private', 'ontology')
     and c.relkind in ('r', 'v', 'm', 'p')
     and pg_catalog.has_table_privilege('semantic_worker', c.oid, 'select');

  if reachable_public <> 0 then
    raise exception
      'semantic_worker can read % tables outside semantic_private', reachable_public;
  end if;
end
$$;

commit;
