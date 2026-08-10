-- 0048 — the legacy bridge.
--
-- `0042`–`0047` reference `auth.users` thirty-one times and the legacy
-- `public.*` tables exactly zero times. The semantic schema is therefore
-- completely decoupled from the shipping app today, and **this migration is the
-- single point at which the two worlds meet.** Everything that has to know
-- about both belongs here and nowhere else.
--
-- It ships no product behaviour. Nothing in Swift reads any of it; every flag
-- it installs is seeded off.
--
-- Five parts:
--
--   A  connector source vs record source, and the foreign key that conflated
--      them. This is the load-bearing change.
--   B  scaffolding for the legacy backfill, including the rule that a backfill
--      can never assert snapshot completeness.
--   C  feature flags, and an emergency privacy switch that needs neither an app
--      release nor a worker deploy.
--   D  the conversation → match-authorization bridge.
--   E  legacy suppressions, kept at the source layer and never at concept level.
--
-- **Every new object is granted explicitly.** `0043` grants
-- `select, insert, update on all tables in schema semantic_private to
-- service_role`, and `on all tables` binds at execution time rather than going
-- forward — so a table added here receives no grant at all unless this file
-- says so. That is the trap this migration is most likely to fall into.
--
-- **No executable statement in this file names the app's own `private`
-- schema.** It holds `push_config` (the shared push secret), `notify` and
-- `collaborators`, and "an adapted grant broadens access" is the integration
-- plan's named deployment-failure condition. Re-run the grants fingerprint for
-- `private.push_config` and `private.collaborators` before and after applying
-- this, exactly as `0042`'s header prescribes.

begin;

-- ---------------------------------------------------------------------------
-- Part A — connector source is not record source
-- ---------------------------------------------------------------------------
--
-- `SyncService.push(source:records:)` omits each record's own source and
-- `append_source_records` stamps the batch's, so a `user` row travelling inside
-- an Apple Music run is stored as Apple Music evidence. The semantic schema
-- inherited that defect and then *encoded* it as a constraint:
--
--     foreign key (ingestion_run_id, user_id, source_code)
--       references semantic_private.ingestion_runs(id, user_id, source_code)
--
-- An observation's source was forced equal to its run's. So the fix is not a
-- column, it is a foreign key: the run keeps a **connector** source, every
-- child keeps a **record** source, and the two are joined through a new
-- `connector_source_code` rather than by pretending they are the same value.
--
-- `source_code` deliberately keeps its name and its meaning on the children.
-- It is the record source, which is correct: `sources.action_weights`,
-- `online_resolution_policy` and `default_reliability` are per-record
-- semantics, and repointing them at the connector would be the real
-- regression.

alter table semantic_private.ingestion_runs
  add column if not exists connector_source_code text;

comment on column semantic_private.ingestion_runs.source_code is
  'The connector whose authorization and distillation produced this batch. '
  'Kept under its original name so 0042-0047 need no rewrite; read it as the '
  'connector source. Child rows carry the record source in their own '
  'source_code, and join back through connector_source_code.';

update semantic_private.ingestion_runs
set connector_source_code = source_code
where connector_source_code is null;

alter table semantic_private.ingestion_runs
  alter column connector_source_code set not null;

alter table semantic_private.ingestion_runs
  drop constraint if exists ingestion_runs_connector_matches_v031_check;
alter table semantic_private.ingestion_runs
  add constraint ingestion_runs_connector_matches_v031_check
  check (connector_source_code = source_code);

-- A run's connector source and its own source_code are the same value by
-- construction; the check above says so rather than leaving two columns that
-- could drift. What changes is only what the *children* are allowed to be.

alter table semantic_private.ingestion_runs
  drop constraint if exists ingestion_runs_connector_identity_v031_key;
alter table semantic_private.ingestion_runs
  add constraint ingestion_runs_connector_identity_v031_key
  unique (id, user_id, connector_source_code);

do $$
declare
  child record;
  constraint_name text;
begin
  for child in
    select *
    from (values
      ('observations'),
      ('raw_source_records'),
      ('ingestion_run_scopes')
    ) as t(table_name)
  loop
    -- Add the connector column and seed it from what the row already claims.
    -- Before this migration the two were identical by force, so the backfill is
    -- exact rather than a guess.
    execute format(
      'alter table semantic_private.%I add column if not exists connector_source_code text',
      child.table_name
    );
    execute format(
      'update semantic_private.%I set connector_source_code = source_code
         where connector_source_code is null',
      child.table_name
    );
    execute format(
      'alter table semantic_private.%I alter column connector_source_code set not null',
      child.table_name
    );

    -- The composite foreign keys are unnamed in 0042/0046/0047, so they must be
    -- discovered rather than guessed at. Match on the referenced table and the
    -- exact referencing columns.
    for constraint_name in
      select con.conname
      from pg_constraint as con
      join pg_class as rel on rel.oid = con.conrelid
      join pg_class as ref on ref.oid = con.confrelid
      where con.contype = 'f'
        and rel.relnamespace = 'semantic_private'::regnamespace
        and rel.relname = child.table_name
        and ref.relname = 'ingestion_runs'
        and (
          select array_agg(att.attname order by att.attname)
          from unnest(con.conkey) as k(attnum)
          join pg_attribute as att
            on att.attrelid = con.conrelid and att.attnum = k.attnum
        ) = array['ingestion_run_id', 'source_code', 'user_id']
    loop
      execute format(
        'alter table semantic_private.%I drop constraint %I',
        child.table_name, constraint_name
      );
    end loop;

    execute format(
      'alter table semantic_private.%I
         add constraint %I
         foreign key (ingestion_run_id, user_id, connector_source_code)
         references semantic_private.ingestion_runs(id, user_id, connector_source_code)
         %s deferrable initially deferred',
      child.table_name,
      child.table_name || '_run_connector_v031_fkey',
      case when child.table_name = 'ingestion_run_scopes'
           then 'on delete cascade'
           else 'on delete no action'
      end
    );
  end loop;
end;
$$;

-- `ingestion_run_items` needs no repoint: its composite key references
-- `ingestion_run_scopes`, not the run, and both sides now mean the record
-- source. The existing constraint already keeps an item and its scope in step.

comment on column semantic_private.observations.source_code is
  'The record source: whose semantics and policy govern THIS row. Not the '
  'connector that fetched it. A user or connection row arriving inside an '
  'apple_music batch is a user row.';
comment on column semantic_private.observations.connector_source_code is
  'The connector whose authorization produced the batch this row arrived in.';
comment on column semantic_private.raw_source_records.source_code is
  'The record source. `consent_purpose` keys off this and must continue to: a '
  'calendar row inside another connector''s batch still needs calendar consent.';

-- The legal pairs, so a mixed batch cannot claim an arbitrary combination.
create table if not exists semantic_private.connector_record_source_matrix (
  connector_source_code text not null
    references semantic_private.sources(source_code) on delete restrict,
  record_source_code text not null
    references semantic_private.sources(source_code) on delete restrict,
  rationale text not null,
  created_at timestamptz not null default now(),
  primary key (connector_source_code, record_source_code)
);

comment on table semantic_private.connector_record_source_matrix is
  'Which record sources a given connector is allowed to deliver. Every '
  'connector may deliver its own rows; anything else has to be stated here '
  'with a reason, so a batch cannot quietly relabel evidence.';

-- Every source may always deliver its own records. Cross-source pairs are
-- deliberately not seeded: the app does not produce them yet, and a permission
-- added before there is a caller is a permission nobody reviews.
insert into semantic_private.connector_record_source_matrix
  (connector_source_code, record_source_code, rationale)
select source_code, source_code, 'a connector may always deliver its own records'
from semantic_private.sources
on conflict (connector_source_code, record_source_code) do nothing;

create or replace function semantic_private.guard_connector_record_source_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and new.connector_source_code is distinct from old.connector_source_code then
    raise exception 'connector provenance is append-only';
  end if;
  if not exists (
    select 1
    from semantic_private.connector_record_source_matrix as matrix
    where matrix.connector_source_code = new.connector_source_code
      and matrix.record_source_code = new.source_code
  ) then
    raise exception
      'connector % may not deliver % records',
      new.connector_source_code, new.source_code;
  end if;
  return new;
end;
$$;

drop trigger if exists observations_guard_connector_source_v031
  on semantic_private.observations;
create trigger observations_guard_connector_source_v031
before insert or update of connector_source_code, source_code
on semantic_private.observations
for each row execute function semantic_private.guard_connector_record_source_v031();

drop trigger if exists raw_source_records_guard_connector_source_v031
  on semantic_private.raw_source_records;
create trigger raw_source_records_guard_connector_source_v031
before insert or update of connector_source_code, source_code
on semantic_private.raw_source_records
for each row execute function semantic_private.guard_connector_record_source_v031();

-- `guard_observation_immutable` protects every provenance field on an
-- observation and would have left the new one mutable — which is the whole
-- point of the column, so it is added to the chain rather than left to the
-- trigger above.
create or replace function semantic_private.guard_observation_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.ingestion_run_id is distinct from old.ingestion_run_id
     or new.source_code is distinct from old.source_code
     or new.connector_source_code is distinct from old.connector_source_code
     or new.data_type is distinct from old.data_type
     or new.observation_kind is distinct from old.observation_kind
     or new.action_type is distinct from old.action_type
     or new.occurred_at is distinct from old.occurred_at
     or new.ingested_at is distinct from old.ingested_at
     or new.source_item_hmac is distinct from old.source_item_hmac
     or new.record_fingerprint is distinct from old.record_fingerprint
     or new.content_lineage_hmac is distinct from old.content_lineage_hmac
     or new.session_hmac is distinct from old.session_hmac
     or new.payload_schema_version is distinct from old.payload_schema_version
     or new.normalized_payload is distinct from old.normalized_payload
     or new.raw_blob_ref is distinct from old.raw_blob_ref
     or new.field_quality is distinct from old.field_quality
     or new.action_weight is distinct from old.action_weight
     or new.privacy_class is distinct from old.privacy_class
     or new.allow_external_resolution is distinct from old.allow_external_resolution
     or new.created_at is distinct from old.created_at
  then
    raise exception 'observation evidence is append-only';
  end if;
  return new;
end;
$$;

create index if not exists observations_connector_source_v031_idx
  on semantic_private.observations (user_id, connector_source_code, ingested_at desc);

-- ---------------------------------------------------------------------------
-- Part A, continued — the finalizer must partition by RECORD source
-- ---------------------------------------------------------------------------
--
-- Almost all of `finalize_ingestion_run_v031` was already correct: it works
-- through `scope_row`, `item_row` and `current_row`, each of which carries its
-- own source. Exactly two statements reached for the *run's* source instead,
-- and both touch `source_state_heads` — whose rows are created from
-- `scope_row.source_code`, i.e. the record source.
--
-- While a run could only ever carry its own source those two agreed, so this is
-- latent rather than broken today. It stops being latent the moment a
-- cross-source pair is added to `connector_record_source_matrix`: heads
-- belonging to a different record source would be skipped by the head advance
-- and left behind by the placeholder cleanup, which is silent divergence in the
-- one structure the current-state contract depends on.
--
-- Replaced whole because Postgres has no way to patch part of a function body.
-- The diff against `0047`'s version is exactly those two statements: the head
-- filter is dropped from the outer predicate and re-expressed as a correlation
-- on `scope.source_code = head.source_code`, so a mixed batch advances each
-- record source's head on its own. Behaviour is identical wherever scope source
-- equals run source, which is every row that exists today.

create or replace function semantic_private.finalize_ingestion_run_v031(
  target_ingestion_run_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
  head_row semantic_private.source_state_heads%rowtype;
  scope_row semantic_private.ingestion_run_scopes%rowtype;
  item_row semantic_private.ingestion_run_items%rowtype;
  current_row semantic_private.current_source_items%rowtype;
  desired_state text;
  changed_count integer := 0;
  scope_count integer;
  actual_count integer;
  new_revision bigint;
  ontology_version_id_value uuid;
  resolver_model_id_value uuid;
  scorer_model_id_value uuid;
  embedding_model_id_value uuid;
  job_payload jsonb;
  receipt jsonb;
  superseded_scope_key_value text;
begin
  if target_ingestion_run_id is null then
    raise exception 'ingestion run id is required';
  end if;

  select * into run_row
  from semantic_private.ingestion_runs
  where id = target_ingestion_run_id
  for update;
  if not found then
    raise exception 'ingestion run not found';
  end if;
  if run_row.status in ('succeeded', 'superseded')
     and run_row.finalization_receipt is not null then
    return run_row.finalization_receipt;
  end if;
  if run_row.status <> 'running' then
    raise exception 'only a running ingestion run can be finalized';
  end if;

  select count(*) into scope_count
  from semantic_private.ingestion_run_scopes
  where ingestion_run_id = run_row.id;
  if scope_count = 0 then
    raise exception 'finalization requires at least one immutable scope manifest';
  end if;
  for scope_row in
    select * from semantic_private.ingestion_run_scopes
    where ingestion_run_id = run_row.id
    order by scope_key
  loop
    select count(*) into actual_count
    from semantic_private.ingestion_run_items
    where ingestion_run_id = scope_row.ingestion_run_id
      and scope_key = scope_row.scope_key;
    if scope_row.completeness = 'complete'
       and actual_count <> scope_row.expected_item_count then
      raise exception 'complete scope % expected % items but received %',
        scope_row.scope_key, scope_row.expected_item_count, actual_count;
    end if;
  end loop;

  -- Heads are scoped, not merely source-wide. Overlapping scopes serialize in
  -- lexical order, while independent source scopes may finalize without one
  -- incorrectly superseding the other.
  for scope_row in
    select * from semantic_private.ingestion_run_scopes
    where ingestion_run_id = run_row.id
    order by scope_key
  loop
    insert into semantic_private.source_state_heads (
      user_id, source_code, scope_key, data_type, action_type
    ) values (
      scope_row.user_id, scope_row.source_code, scope_row.scope_key,
      scope_row.data_type, scope_row.action_type
    )
    on conflict (user_id, source_code, scope_key) do nothing;
  end loop;
  -- Lock every scope in the same order before deciding whether any overlap is
  -- stale. This prevents a mixed-scope run from mutating one head and only
  -- later discovering that another scope supersedes the entire atomic run.
  for scope_row in
    select * from semantic_private.ingestion_run_scopes
    where ingestion_run_id = run_row.id
    order by scope_key
  loop
    select * into head_row
    from semantic_private.source_state_heads
    where user_id = scope_row.user_id
      and source_code = scope_row.source_code
      and scope_key = scope_row.scope_key
    for update;
    if head_row.data_type is distinct from scope_row.data_type
       or head_row.action_type is distinct from scope_row.action_type then
      raise exception 'scope key cannot change data/action identity';
    end if;
    if superseded_scope_key_value is null
       and head_row.latest_run_id is not null and (
         run_row.started_at < head_row.latest_run_started_at
         or (
           run_row.started_at = head_row.latest_run_started_at
           and run_row.id::text < head_row.latest_run_id::text
         )
       ) then
      superseded_scope_key_value := scope_row.scope_key;
    end if;
  end loop;

  if superseded_scope_key_value is not null then
    select coalesce(state.revision, 0) into new_revision
    from semantic_private.user_state_versions as state
    where state.user_id = run_row.user_id;
    if not found then new_revision := 0; end if;
    receipt := jsonb_build_object(
      'ingestion_run_id', run_row.id::text,
      'status', 'superseded',
      'state_changed', false,
      'changed_item_count', 0,
      'finalization_revision', new_revision,
      'superseded_scope_key', superseded_scope_key_value,
      'policy_version', 'written-current-state-v1.0.0'
    );
    -- Remove only placeholder heads created while locking this run's scopes;
    -- a superseded run must not leave metadata authority behind.
    delete from semantic_private.source_state_heads as head
    where head.user_id = run_row.user_id
      and head.latest_run_id is null
      and exists (
        select 1 from semantic_private.ingestion_run_scopes as scope
        where scope.ingestion_run_id = run_row.id
          and scope.scope_key = head.scope_key
          and scope.source_code = head.source_code
      );
    perform set_config('written.finalize_ingestion_v031', '1', true);
    update semantic_private.ingestion_runs
    set status = 'superseded', finished_at = now(),
        finalization_revision = null,
        finalization_receipt = receipt,
        current_state_policy_version = 'written-current-state-v1.0.0'
    where id = run_row.id;
    perform set_config('written.finalize_ingestion_v031', '0', true);
    return receipt;
  end if;

  perform set_config('written.finalize_ingestion_v031', '1', true);

  for item_row in
    select item.*
    from semantic_private.ingestion_run_items as item
    where item.ingestion_run_id = run_row.id
    order by item.scope_key, item.source_item_hmac
  loop
    desired_state := case
      when item_row.item_state = 'provider_deleted' then 'provider_deleted'
      else 'present'
    end;
    select current_item.* into current_row
    from semantic_private.current_source_items as current_item
    join semantic_private.ingestion_run_scopes as scope
      on scope.ingestion_run_id = item_row.ingestion_run_id
     and scope.scope_key = item_row.scope_key
    where current_item.user_id = item_row.user_id
      and current_item.source_code = item_row.source_code
      and current_item.scope_key = item_row.scope_key
      and current_item.data_type = scope.data_type
      and current_item.action_type = scope.action_type
      and current_item.source_item_hmac = item_row.source_item_hmac
    for update of current_item;
    if not found then
      insert into semantic_private.current_source_items (
        user_id, source_code, scope_key, data_type, action_type,
        source_item_hmac, record_fingerprint,
        current_raw_source_record_id, current_observation_id, occurred_at,
        lifecycle_state, first_seen_at, last_seen_at, state_changed_at,
        last_seen_run_id, last_change_run_id
      )
      select item_row.user_id, item_row.source_code, item_row.scope_key,
             scope.data_type, scope.action_type,
             item_row.source_item_hmac, item_row.record_fingerprint,
             item_row.raw_source_record_id, item_row.observation_id,
             item_row.occurred_at, desired_state, now(), now(), now(),
             item_row.ingestion_run_id, item_row.ingestion_run_id
      from semantic_private.ingestion_run_scopes as scope
      where scope.ingestion_run_id = item_row.ingestion_run_id
        and scope.scope_key = item_row.scope_key;
      changed_count := changed_count + 1;
    elsif current_row.record_fingerprint is distinct from item_row.record_fingerprint
       or current_row.current_raw_source_record_id is distinct from item_row.raw_source_record_id
       or current_row.current_observation_id is distinct from item_row.observation_id
       or current_row.occurred_at is distinct from item_row.occurred_at
       or current_row.lifecycle_state is distinct from desired_state then
      update semantic_private.current_source_items
      set record_fingerprint = item_row.record_fingerprint,
          current_raw_source_record_id = item_row.raw_source_record_id,
          current_observation_id = item_row.observation_id,
          occurred_at = item_row.occurred_at,
          lifecycle_state = desired_state,
          last_seen_at = now(),
          state_changed_at = now(),
          last_seen_run_id = item_row.ingestion_run_id,
          last_change_run_id = item_row.ingestion_run_id
      where user_id = current_row.user_id
        and source_code = current_row.source_code
        and scope_key = current_row.scope_key
        and data_type = current_row.data_type
        and action_type = current_row.action_type
        and source_item_hmac = current_row.source_item_hmac;
      changed_count := changed_count + 1;
    else
      update semantic_private.current_source_items
      set last_seen_at = now(), last_seen_run_id = item_row.ingestion_run_id
      where user_id = current_row.user_id
        and source_code = current_row.source_code
        and scope_key = current_row.scope_key
        and data_type = current_row.data_type
        and action_type = current_row.action_type
        and source_item_hmac = current_row.source_item_hmac;
    end if;

    if item_row.observation_id is not null then
      update semantic_private.observations
      set lifecycle_state = case
            when desired_state = 'present' then 'active'
            else 'excluded'
          end,
          exclusion_code = case
            when desired_state = 'present' then null
            else 'provider_deleted'
          end,
          excluded_at = case
            when desired_state = 'present' then null
            else coalesce(excluded_at, now())
          end
      where id = item_row.observation_id
        and user_id = item_row.user_id
        and (
          lifecycle_state is distinct from case
            when desired_state = 'present' then 'active'
            else 'excluded'
          end
          or exclusion_code is distinct from case
            when desired_state = 'present' then null
            else 'provider_deleted'
          end
        );
    end if;
  end loop;

  -- Only an explicitly complete full snapshot can infer absence. Partial,
  -- truncated, and delta scopes leave unseen items in their previous state.
  for scope_row in
    select * from semantic_private.ingestion_run_scopes
    where ingestion_run_id = run_row.id
      and snapshot_mode = 'full_snapshot'
      and completeness = 'complete'
    order by scope_key
  loop
    for current_row in
      select current_item.*
      from semantic_private.current_source_items as current_item
      where current_item.user_id = scope_row.user_id
        and current_item.source_code = scope_row.source_code
        and current_item.scope_key = scope_row.scope_key
        and current_item.data_type = scope_row.data_type
        and current_item.action_type = scope_row.action_type
        and current_item.lifecycle_state = 'present'
        and (
          scope_row.window_start is null
          or current_item.occurred_at is null
          or current_item.occurred_at >= scope_row.window_start
        )
        and (
          scope_row.window_end is null
          or current_item.occurred_at is null
          or current_item.occurred_at <= scope_row.window_end
        )
        and not exists (
          select 1
          from semantic_private.ingestion_run_items as item
          where item.ingestion_run_id = scope_row.ingestion_run_id
            and item.scope_key = scope_row.scope_key
            and item.source_item_hmac = current_item.source_item_hmac
        )
      for update
    loop
      update semantic_private.current_source_items
      set lifecycle_state = 'absent_from_snapshot',
          state_changed_at = now(),
          last_change_run_id = run_row.id
      where user_id = current_row.user_id
        and source_code = current_row.source_code
        and scope_key = current_row.scope_key
        and data_type = current_row.data_type
        and action_type = current_row.action_type
        and source_item_hmac = current_row.source_item_hmac;
      changed_count := changed_count + 1;
      if current_row.current_observation_id is not null then
        update semantic_private.observations
        set lifecycle_state = 'excluded',
            exclusion_code = 'snapshot_absent',
            excluded_at = coalesce(excluded_at, now())
        where id = current_row.current_observation_id
          and user_id = current_row.user_id
          and lifecycle_state is distinct from 'excluded';
      end if;
    end loop;
  end loop;

  select coalesce(state.revision, 0) into new_revision
  from semantic_private.user_state_versions as state
  where state.user_id = run_row.user_id;
  if not found then new_revision := 0; end if;

  if changed_count > 0 then
    insert into semantic_private.user_state_versions (user_id, revision)
    values (run_row.user_id, 1)
    on conflict (user_id) do update
    set revision = semantic_private.user_state_versions.revision + 1,
        updated_at = now()
    returning revision into new_revision;

    select id into ontology_version_id_value
    from ontology.versions
    where status = 'published'
    order by created_at desc, id
    limit 1;
    select id into resolver_model_id_value
    from ontology.model_versions
    where model_role = 'resolver' and status = 'active'
    order by created_at desc, id
    limit 1;
    select id into scorer_model_id_value
    from ontology.model_versions
    where model_role = 'scorer' and status = 'active'
    order by created_at desc, id
    limit 1;
    select id into embedding_model_id_value
    from ontology.embedding_models
    where status = 'active'
    order by created_at desc, id
    limit 1;
    if ontology_version_id_value is null
       or resolver_model_id_value is null
       or scorer_model_id_value is null then
      raise exception 'finalization requires published ontology and active resolver/scorer models';
    end if;
    job_payload := jsonb_build_object(
      'user_id', run_row.user_id::text,
      'input_revision', new_revision,
      'ontology_version_id', ontology_version_id_value::text,
      'resolver_model_id', resolver_model_id_value::text,
      'scorer_model_id', scorer_model_id_value::text
    );
    if embedding_model_id_value is not null then
      job_payload := job_payload || jsonb_build_object(
        'embedding_model_id', embedding_model_id_value::text
      );
    end if;
    insert into semantic_private.worker_jobs (
      job_type, user_id, payload, idempotency_key
    ) values (
      'recompute_user', run_row.user_id, job_payload,
      'ingestion-v031-recompute:' || run_row.user_id::text
        || ':' || new_revision::text
    )
    on conflict (idempotency_key) do nothing;
  end if;

  receipt := jsonb_build_object(
    'ingestion_run_id', run_row.id::text,
    'status', 'succeeded',
    'state_changed', changed_count > 0,
    'changed_item_count', changed_count,
    'finalization_revision', new_revision,
    'policy_version', 'written-current-state-v1.0.0'
  );
  update semantic_private.ingestion_runs
  set status = 'succeeded', finished_at = now(),
      finalization_revision = new_revision,
      finalization_receipt = receipt,
      current_state_policy_version = 'written-current-state-v1.0.0'
  where id = run_row.id;
  update semantic_private.source_state_heads as head
  set latest_run_started_at = run_row.started_at,
      latest_run_id = run_row.id,
      current_revision = new_revision,
      updated_at = now()
  where head.user_id = run_row.user_id
    and exists (
      select 1
      from semantic_private.ingestion_run_scopes as scope
      where scope.ingestion_run_id = run_row.id
        and scope.scope_key = head.scope_key
        and scope.source_code = head.source_code
    );
  perform set_config('written.finalize_ingestion_v031', '0', true);
  return receipt;
end;
$$;

-- ---------------------------------------------------------------------------
-- Part B — legacy backfill scaffolding
-- ---------------------------------------------------------------------------
--
-- `0004`–`0006` store the latest version ever seen of each key. They record no
-- run membership, no absence, no provider deletion and no lookback expiry — so
-- a legacy row cannot answer "is this still true", only "this was true once".
-- Everything here exists to stop that distinction being lost on import.

alter table semantic_private.ingestion_runs
  add column if not exists run_kind text not null default 'connector';
alter table semantic_private.ingestion_runs
  drop constraint if exists ingestion_runs_run_kind_v031_check;
alter table semantic_private.ingestion_runs
  add constraint ingestion_runs_run_kind_v031_check
  check (run_kind in ('connector', 'legacy_backfill'));

alter table semantic_private.observations
  add column if not exists provenance_tier text not null default 'typed';
alter table semantic_private.observations
  drop constraint if exists observations_provenance_tier_v031_check;
alter table semantic_private.observations
  add constraint observations_provenance_tier_v031_check
  check (provenance_tier in ('typed', 'legacy_unverified'));
alter table semantic_private.observations
  add column if not exists legacy_backfilled_at timestamptz;

comment on column semantic_private.observations.provenance_tier is
  'legacy_unverified marks a row imported from public.distilled_records. It is '
  'history, not current state: `observation_is_current_v031` refuses it, so it '
  'can never reach a candidate or accepted mapping without a fresh typed '
  'distillation.';

-- **A backfill may never claim a complete full snapshot.** This is §7's "never
-- infer complete snapshot membership from latest-ever rows" as a constraint
-- rather than a note, because the legacy schema genuinely cannot support the
-- claim and the temptation to assert it is highest during a migration.
create or replace function semantic_private.guard_legacy_backfill_scope_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  kind text;
begin
  select run_kind into kind
  from semantic_private.ingestion_runs
  where id = new.ingestion_run_id;

  if kind = 'legacy_backfill'
     and new.completeness = 'complete'
     and new.snapshot_mode = 'full_snapshot' then
    raise exception
      'a legacy backfill cannot assert a complete full snapshot: the legacy '
      'store records the latest version ever seen, never run membership';
  end if;
  return new;
end;
$$;

drop trigger if exists ingestion_run_scopes_guard_legacy_backfill_v031
  on semantic_private.ingestion_run_scopes;
create trigger ingestion_run_scopes_guard_legacy_backfill_v031
before insert or update of completeness, snapshot_mode
on semantic_private.ingestion_run_scopes
for each row execute function semantic_private.guard_legacy_backfill_scope_v031();

-- A legacy row is never current. `guard_mapping_current_source_v031` already
-- refuses a candidate or accepted mapping whose observation is not current, so
-- adding the tier here closes the promotion path in one place rather than in
-- every caller.
create or replace function semantic_private.observation_is_current_v031(
  target_observation_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.current_source_items as item
    join semantic_private.observations as observation
      on observation.id = item.current_observation_id
     and observation.user_id = item.user_id
    where item.current_observation_id = target_observation_id
      and item.user_id = target_user_id
      and item.lifecycle_state = 'present'
      and observation.provenance_tier = 'typed'
  );
$$;

create table if not exists semantic_private.legacy_ingestion_runs (
  user_id uuid not null references auth.users(id) on delete cascade,
  legacy_source text not null,
  legacy_distilled_at timestamptz not null,
  ingestion_run_id uuid not null,
  imported_at timestamptz not null default now(),
  primary key (user_id, legacy_source, legacy_distilled_at),
  unique (ingestion_run_id),
  foreign key (ingestion_run_id, user_id)
    references semantic_private.ingestion_runs(id, user_id) on delete cascade
);

comment on table semantic_private.legacy_ingestion_runs is
  'Correlates one legacy distillation with the run created to carry it. '
  '(user_id, source, distilled_at) IS the legacy run identity — 0006 promoted '
  'distilled_at into the primary key of public.distilled_records for exactly '
  'this reason, and it is the only join key the old schema offers.';

create table if not exists semantic_private.legacy_record_links (
  observation_id uuid not null,
  user_id uuid not null,
  legacy_source text not null,
  legacy_data_type text not null,
  legacy_item_id text not null,
  legacy_distilled_at timestamptz not null,
  primary key (user_id, legacy_source, legacy_data_type, legacy_item_id, legacy_distilled_at),
  unique (observation_id),
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade
);

comment on table semantic_private.legacy_record_links is
  'The full four-part legacy primary key against the observation it became. '
  'Makes re-running the backfill idempotent, and makes shadow comparison '
  'possible without inventing evidence to compare against.';

create table if not exists semantic_private.legacy_backfill_policies (
  legacy_relation text primary key,
  policy text not null check (policy in (
    'import_legacy_unverified', 'shadow_only', 'no_import'
  )),
  rationale text not null
);

comment on table semantic_private.legacy_backfill_policies is
  'The contract''s backfill table, executable rather than prose, so the '
  'release gate can be audited in SQL. Backfill is a provenance migration, '
  'never permission to invent current truth.';

insert into semantic_private.legacy_backfill_policies
  (legacy_relation, policy, rationale)
values
  ('public.distilled_records', 'import_legacy_unverified',
   'Import with original source, action and timestamps where reliable. Never '
   'infer complete snapshot membership from latest-ever rows.'),
  ('public.health_signals', 'no_import',
   'Derived product history. A v0.3.1 fitness assertion requires a fresh typed '
   'HealthKit distillation under a recorded fitness_connection purpose grant.'),
  ('public.health_sports', 'no_import',
   'Same rule, and empty in any case: measured 2026-08-10, zero rows, because '
   'no device in the cohort records structured workouts. Aggregate-only '
   'HealthKit coverage must abstain rather than be promoted.'),
  ('public.discovery_cards', 'shadow_only',
   'Client-authored semantic JSON. Diagnostics and user review only; it '
   'bypassed evidence lineage, surface grants and revision checks entirely.'),
  ('public.conversations.theme', 'shadow_only',
   'Legacy creator-overlap themes are not validated frames. Already-exposed '
   'text is historical and is neither imported nor rewritten.'),
  ('public.bans', 'import_legacy_unverified',
   'Imported as source-local suppressions only. A title ban must never become '
   'a concept-level negative.'),
  ('youtube', 'no_import',
   'Fail-closed by construction: 0045 gates YouTube on an approved policy and '
   'none exists, so this backfills to zero rows today. Recorded explicitly '
   'rather than left to luck, and note ARCHIVED- is a client-side list, not '
   'evidence of revocation.')
on conflict (legacy_relation) do update
  set policy = excluded.policy,
      rationale = excluded.rationale;

-- ---------------------------------------------------------------------------
-- Part C — flags, and a kill switch that needs no release
-- ---------------------------------------------------------------------------
--
-- `AppConfig.swift` is a compile-time enum of static lets, so this app has no
-- feature-flag mechanism at all. The rollback contract requires one:
-- independent switches for typed ingestion, shadow computation, Memories,
-- discovery/profile reads, icebreaker first exposure and HealthKit use, plus an
-- emergency privacy switch that "must not depend on a new app release".
--
-- **A flag the client reads is not a kill switch.** It must not depend on a
-- worker deploy either, which is why the three server-side entry points below
-- consult it directly. Flipping one row then halts promotion and cross-user
-- exposure while deleting nothing.

create table if not exists semantic_private.feature_flags (
  flag_key text primary key,
  enabled boolean not null default false,
  cohort text not null default 'off' check (cohort in ('off', 'internal', 'canary', 'all')),
  description text not null,
  updated_at timestamptz not null default now(),
  updated_by text
);

create table if not exists semantic_private.feature_flag_overrides (
  flag_key text not null references semantic_private.feature_flags(flag_key) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  enabled boolean not null,
  updated_at timestamptz not null default now(),
  primary key (flag_key, user_id)
);

insert into semantic_private.feature_flags (flag_key, description)
values
  ('typed_ingestion', 'Accept typed source envelopes into the private vault.'),
  ('semantic_shadow_compute', 'Run classifiers, mapping and scoring without publishing.'),
  ('memories_reads', 'Owner-only assertion snapshots through the api schema.'),
  ('discovery_profile_reads', 'Server-owned discovery and matched-profile projections.'),
  ('icebreaker_first_exposure', 'Allow an unexposed frame to cross first exposure.'),
  ('healthkit_fitness_use', 'Use HealthKit evidence under the fitness_connection purpose.'),
  ('emergency_privacy_kill_switch',
   'Master stop. When enabled, promotion and cross-user exposure are refused '
   'regardless of every other flag. Deletes nothing and preserves the audit '
   'trail; it exists so a privacy incident does not wait on an app release.')
on conflict (flag_key) do nothing;

create or replace function semantic_private.flag_enabled_v031(
  target_flag_key text,
  target_user_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (
      select 1 from semantic_private.feature_flags
      where flag_key = 'emergency_privacy_kill_switch' and enabled
    ) and target_flag_key <> 'emergency_privacy_kill_switch'
    then false
    else coalesce(
      (
        select override.enabled
        from semantic_private.feature_flag_overrides as override
        where override.flag_key = target_flag_key
          and override.user_id = target_user_id
      ),
      (
        select flag.enabled
        from semantic_private.feature_flags as flag
        where flag.flag_key = target_flag_key
      ),
      false
    )
  end;
$$;

comment on function semantic_private.flag_enabled_v031(text, uuid) is
  'Fail-closed: an unknown flag is off, and the emergency switch overrides '
  'every other answer including a per-user override.';

-- The api-schema reader. Returns only what the caller is entitled to know
-- about themselves, and never accepts a user id from the client.
create or replace function api.feature_flags()
returns table (flag_key text, enabled boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select flag.flag_key,
         semantic_private.flag_enabled_v031(flag.flag_key, (select auth.uid()))
  from semantic_private.feature_flags as flag
  where (select auth.uid()) is not null
  order by flag.flag_key;
$$;

-- ---------------------------------------------------------------------------
-- Part D — the conversation → match-authorization bridge
-- ---------------------------------------------------------------------------
--
-- `match_authorizations.match_id` is a bare `uuid not null unique` with no
-- foreign key. That absence is the seam, and this is what fills it.
--
-- **Conversations only, never `public.likes`.** A `conversations` row in `0009`
-- is a mutual accept; a like is a one-sided invitation. The acceptance gate is
-- explicit that a matched profile must not stay readable merely because some
-- historical like row exists, so a like must not create an authorization here.
-- Anyone tempted to add a trigger on `public.likes` later should read that
-- sentence first.

create table if not exists semantic_private.legacy_match_bridge (
  conversation_id uuid primary key
    references public.conversations(id) on delete cascade,
  match_authorization_id uuid not null unique
    references semantic_private.match_authorizations(id) on delete cascade,
  participant_a_user_id uuid not null references auth.users(id) on delete cascade,
  participant_b_user_id uuid not null references auth.users(id) on delete cascade,
  bridged_at timestamptz not null default now(),
  source_version text not null default 'written-legacy-bridge-v1.0.0',
  constraint legacy_match_bridge_ordered_pair_v031_check
    check (participant_a_user_id < participant_b_user_id)
);

comment on table semantic_private.legacy_match_bridge is
  'One legacy conversation against the match authorization it justifies. The '
  'pair is stored least-first so an unordered pair has exactly one '
  'representation, which is what "only one active match per unordered pair" '
  'needs in order to be checkable.';

comment on constraint legacy_match_bridge_ordered_pair_v031_check
  on semantic_private.legacy_match_bridge is
  'Normalizing with least/greatest before insert is the caller''s job; this '
  'refuses the row if they did not, rather than storing both orderings.';

-- ---------------------------------------------------------------------------
-- Part E — legacy suppressions
-- ---------------------------------------------------------------------------
--
-- `public.bans` is keyed by title. A title is not an assertion and not a
-- concept, so importing one as either would manufacture a claim the user never
-- made: striking "Bartholomew" off a page is not a statement about art.
--
-- Deliberately a different table from `user_suppressions`, which is
-- assertion-scoped. These live at the raw/source layer and have no concept
-- foreign key — see the comment, which is the rule.

create table if not exists semantic_private.legacy_suppressions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_code text references semantic_private.sources(source_code) on delete restrict,
  suppression_scope text not null check (
    suppression_scope in ('source_item', 'source_title_key')
  ),
  key_hmac text not null check (key_hmac ~ '^[0-9a-f]{64}$'),
  legacy_ban_kind text,
  created_at timestamptz not null default now(),
  unique (user_id, source_code, suppression_scope, key_hmac)
);

comment on table semantic_private.legacy_suppressions is
  'Imported public.bans, as source-local suppressions. **No ontology.concepts '
  'foreign key may ever be added to this table.** A title ban is not a '
  'concept-level negative, and turning one into a global mapping negative is '
  'the specific mistake the contract names. New Memories removals go through '
  'the assertion-specific no-reason RPC instead.';

comment on column semantic_private.legacy_suppressions.key_hmac is
  'HMAC, never the title. Raw calendar and title text belongs only in the '
  'encrypted owner vault, never in a durable index, log or candidate row.';

-- ---------------------------------------------------------------------------
-- Grants — explicit, because `on all tables` bound at execution time
-- ---------------------------------------------------------------------------

revoke all on table semantic_private.connector_record_source_matrix
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.legacy_ingestion_runs
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.legacy_record_links
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.legacy_backfill_policies
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.feature_flags
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.feature_flag_overrides
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.legacy_match_bridge
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.legacy_suppressions
  from public, anon, authenticated, service_role;

grant select on table semantic_private.connector_record_source_matrix to service_role;
grant select on table semantic_private.legacy_backfill_policies to service_role;
grant select, insert, update on table semantic_private.legacy_ingestion_runs to service_role;
grant select, insert, update on table semantic_private.legacy_record_links to service_role;
grant select, insert, update on table semantic_private.feature_flags to service_role;
grant select, insert, update on table semantic_private.feature_flag_overrides to service_role;
grant select, insert, update on table semantic_private.legacy_match_bridge to service_role;
grant select, insert, update on table semantic_private.legacy_suppressions to service_role;

revoke all on function semantic_private.flag_enabled_v031(text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function semantic_private.guard_connector_record_source_v031()
  from public, anon, authenticated, service_role;
revoke all on function semantic_private.guard_legacy_backfill_scope_v031()
  from public, anon, authenticated, service_role;
grant execute on function semantic_private.flag_enabled_v031(text, uuid) to service_role;

revoke all on function api.feature_flags() from public, anon, authenticated, service_role;
grant execute on function api.feature_flags() to authenticated;

alter table semantic_private.connector_record_source_matrix enable row level security;
alter table semantic_private.legacy_ingestion_runs enable row level security;
alter table semantic_private.legacy_record_links enable row level security;
alter table semantic_private.legacy_backfill_policies enable row level security;
alter table semantic_private.feature_flags enable row level security;
alter table semantic_private.feature_flag_overrides enable row level security;
alter table semantic_private.legacy_match_bridge enable row level security;
alter table semantic_private.legacy_suppressions enable row level security;

-- Row-level security is enabled and deliberately carries no policy on any of
-- these. Nothing may read them as a client: `service_role` reaches them by
-- privilege and bypasses RLS, `api.feature_flags()` is `security definer`, and
-- a table with RLS on and no policy denies every other caller by default. That
-- is the intended posture, not an omission — the same shape as
-- `private.push_config`.

commit;
