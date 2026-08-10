-- Current-state heads, terminal transitions, and surface hardening.
--
-- Adapted from the v0.3.1 package's `006_current_state_and_surface_hardening.sql`. The namespace rule and the
-- reason for it are in `0042_semantic_schema.sql`: the reference chain uses
-- `private` for its own objects and this app already owns that schema, so every
-- qualified reference here is `semantic_private`.
--
-- **Only schema references were translated.** Unlike 001 and 002, these files
-- use the word "private" in prose, in exception messages, and as a
-- `sensitivity` check-constraint *value*. Those are left exactly as written; a
-- blanket replace would have changed what the constraint accepts.
--
-- One string literal moved as well: reference line 974 asks
-- `information_schema.columns` whether `validated_surface_facts` already had
-- its attestation columns. Left as 'private' it would have inspected the app's
-- schema, found nothing, and recorded a false answer to a question the
-- surrounding comment says must never be inferred.
--
-- Ships no product behaviour. Nothing in Swift reads any of this.
--
-- Adapted against package v0.3.1, app commit b3e19ae, migration head 0043.

-- Written semantic system package v0.3.1.
--
-- This migration closes four fail-open gaps left by the v0.3 reference
-- implementation:
--   1. immutable evidence is separated from per-run membership and current
--      provider state;
--   2. public surface facts are pinned to one current assertion score and
--      exact user revision;
--   3. every permission-lattice narrowing invalidates dependent products;
--   4. match authorization revocation is terminal and races first exposure
--      on the same locked authorization row.
--
-- Apply after 005_private_ingestion_and_fitness.sql. The file is replay-safe.
begin;

-- -------------------------------------------------------------------------
-- Complete-snapshot membership and current source state.
-- -------------------------------------------------------------------------

alter table semantic_private.ingestion_runs
  add column if not exists finalization_revision bigint,
  add column if not exists finalization_receipt jsonb,
  add column if not exists current_state_policy_version text;

-- Historical terminal runs predate completeness manifests. Keep their audit
-- status but explicitly mark them unverified; they cannot establish current
-- membership and must be followed by a fresh typed snapshot.
drop trigger if exists ingestion_runs_guard_update on semantic_private.ingestion_runs;
update semantic_private.ingestion_runs
set finalization_receipt = jsonb_build_object(
      'ingestion_run_id', id::text,
      'status', status,
      'state_changed', false,
      'changed_item_count', 0,
      'finalization_revision', null,
      'policy_version', 'written-current-state-v1.0.0',
      'reason_code', 'legacy_run_without_completeness_manifest'
    ),
    current_state_policy_version = 'written-current-state-v1.0.0'
where status in ('succeeded', 'superseded')
  and finalization_receipt is null;
create trigger ingestion_runs_guard_update
before update on semantic_private.ingestion_runs
for each row execute function semantic_private.guard_ingestion_run_update();

-- From this migration onward a successful/superseded terminal transition and
-- its receipt are owned exclusively by the atomic finalizer. Connectors may
-- still mark a running attempt failed, but cannot fabricate current state by
-- directly setting status='succeeded'.
create or replace function semantic_private.guard_ingestion_run_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  in_finalizer boolean := coalesce(
    current_setting('written.finalize_ingestion_v031', true), '0'
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
  if not in_finalizer and (
       new.status in ('succeeded', 'superseded')
       or new.finalization_revision is distinct from old.finalization_revision
       or new.finalization_receipt is distinct from old.finalization_receipt
       or new.current_state_policy_version is distinct from old.current_state_policy_version
     ) then
    raise exception 'successful ingestion runs must use the atomic v0.3.1 finalizer';
  end if;
  return new;
end;
$$;

alter table semantic_private.ingestion_runs
  drop constraint if exists ingestion_runs_finalization_v031_check,
  add constraint ingestion_runs_finalization_v031_check check (
    (
      status = 'running'
      and finalization_revision is null
      and finalization_receipt is null
    ) or (
      status = 'failed'
      and finalization_revision is null
      and finalization_receipt is null
    ) or (
      status in ('succeeded', 'superseded')
      and finalization_receipt is not null
      and current_state_policy_version = 'written-current-state-v1.0.0'
    )
  );

create table if not exists semantic_private.ingestion_run_scopes (
  ingestion_run_id uuid not null,
  user_id uuid not null,
  source_code text not null,
  scope_key text not null,
  data_type text not null,
  action_type text not null,
  snapshot_mode text not null,
  completeness text not null,
  window_start timestamptz,
  window_end timestamptz,
  expected_item_count integer,
  created_at timestamptz not null default now(),
  primary key (ingestion_run_id, scope_key),
  unique (ingestion_run_id, user_id, source_code, scope_key),
  unique (
    ingestion_run_id, user_id, source_code, scope_key, data_type, action_type
  ),
  foreign key (ingestion_run_id, user_id, source_code)
    references semantic_private.ingestion_runs(id, user_id, source_code)
    on delete cascade,
  constraint ingestion_run_scopes_key_v031_check check (
    scope_key ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'
    and data_type ~ '^[a-z][a-z0-9_]{0,63}$'
    and action_type ~ '^[a-z][a-z0-9_]{0,63}$'
  ),
  constraint ingestion_run_scopes_mode_v031_check check (
    snapshot_mode in ('full_snapshot', 'delta')
  ),
  constraint ingestion_run_scopes_completeness_v031_check check (
    completeness in ('complete', 'partial', 'truncated')
  ),
  constraint ingestion_run_scopes_window_v031_check check (
    window_start is null or window_end is null or window_start <= window_end
  ),
  constraint ingestion_run_scopes_expected_count_v031_check check (
    expected_item_count is null or expected_item_count >= 0
  ),
  constraint ingestion_run_scopes_complete_manifest_v031_check check (
    completeness <> 'complete' or expected_item_count is not null
  )
);

create table if not exists semantic_private.ingestion_run_items (
  ingestion_run_id uuid not null,
  user_id uuid not null,
  source_code text not null,
  scope_key text not null,
  source_item_hmac text not null,
  record_fingerprint text not null,
  item_state text not null default 'present',
  raw_source_record_id uuid,
  observation_id uuid,
  occurred_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (ingestion_run_id, scope_key, source_item_hmac),
  foreign key (
    ingestion_run_id, user_id, source_code, scope_key
  ) references semantic_private.ingestion_run_scopes(
    ingestion_run_id, user_id, source_code, scope_key
  ) on delete cascade,
  foreign key (raw_source_record_id, user_id)
    references semantic_private.raw_source_records(id, user_id) on delete no action,
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete no action,
  constraint ingestion_run_items_identity_v031_check check (
    source_item_hmac ~ '^[0-9a-f]{64}$'
    and record_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint ingestion_run_items_state_v031_check check (
    item_state in ('present', 'provider_deleted')
  ),
  constraint ingestion_run_items_evidence_v031_check check (
    item_state = 'provider_deleted'
    or num_nonnulls(raw_source_record_id, observation_id) >= 1
  )
);

create index if not exists ingestion_run_items_evidence_v031_idx
  on semantic_private.ingestion_run_items (observation_id, raw_source_record_id);

create table if not exists semantic_private.current_source_items (
  user_id uuid not null references auth.users(id) on delete cascade,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  scope_key text not null,
  data_type text not null,
  action_type text not null,
  source_item_hmac text not null,
  record_fingerprint text not null,
  current_raw_source_record_id uuid,
  current_observation_id uuid,
  occurred_at timestamptz,
  lifecycle_state text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  state_changed_at timestamptz not null default now(),
  last_seen_run_id uuid not null,
  last_change_run_id uuid not null,
  primary key (
    user_id, source_code, scope_key, data_type, action_type, source_item_hmac
  ),
  foreign key (current_raw_source_record_id, user_id)
    references semantic_private.raw_source_records(id, user_id) on delete no action,
  foreign key (current_observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete no action,
  foreign key (last_seen_run_id, user_id, source_code)
    references semantic_private.ingestion_runs(id, user_id, source_code) on delete no action,
  foreign key (last_change_run_id, user_id, source_code)
    references semantic_private.ingestion_runs(id, user_id, source_code) on delete no action,
  constraint current_source_items_identity_v031_check check (
    scope_key ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'
    and data_type ~ '^[a-z][a-z0-9_]{0,63}$'
    and action_type ~ '^[a-z][a-z0-9_]{0,63}$'
    and source_item_hmac ~ '^[0-9a-f]{64}$'
    and record_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint current_source_items_state_v031_check check (
    lifecycle_state in ('present', 'absent_from_snapshot', 'provider_deleted')
  ),
  constraint current_source_items_present_evidence_v031_check check (
    lifecycle_state <> 'present'
    or num_nonnulls(current_raw_source_record_id, current_observation_id) >= 1
  )
);

create index if not exists current_source_items_present_v031_idx
  on semantic_private.current_source_items (
    user_id, source_code, data_type, action_type, occurred_at desc
  ) where lifecycle_state = 'present';
create index if not exists current_source_items_observation_v031_idx
  on semantic_private.current_source_items (current_observation_id)
  where lifecycle_state = 'present' and current_observation_id is not null;

create table if not exists semantic_private.source_state_heads (
  user_id uuid not null references auth.users(id) on delete cascade,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  scope_key text not null,
  data_type text not null,
  action_type text not null,
  latest_run_started_at timestamptz,
  latest_run_id uuid,
  current_revision bigint not null default 0 check (current_revision >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, source_code, scope_key),
  foreign key (latest_run_id, user_id, source_code, scope_key)
    references semantic_private.ingestion_run_scopes(
      ingestion_run_id, user_id, source_code, scope_key
    ) on delete no action,
  constraint source_state_heads_identity_v031_check check (
    scope_key ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'
    and data_type ~ '^[a-z][a-z0-9_]{0,63}$'
    and action_type ~ '^[a-z][a-z0-9_]{0,63}$'
  ),
  constraint source_state_heads_pair_v031_check check (
    num_nonnulls(latest_run_started_at, latest_run_id) in (0, 2)
  )
);

-- A deleted/expired ciphertext row is immutable history. The same logical
-- provider record may later be imported under a new key/retention epoch.
alter table semantic_private.raw_source_records
  drop constraint if exists raw_source_records_user_id_source_code_record_fingerprint_key;
create unique index if not exists raw_source_records_active_fingerprint_v031_idx
  on semantic_private.raw_source_records (user_id, source_code, record_fingerprint)
  where lifecycle_state = 'active';

create or replace function semantic_private.guard_ingestion_scope_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
begin
  if tg_op <> 'INSERT' then
    raise exception 'ingestion scope manifests are append-only';
  end if;
  select * into run_row
  from semantic_private.ingestion_runs
  where id = new.ingestion_run_id
  for key share;
  if not found
     or run_row.status <> 'running'
     or run_row.user_id is distinct from new.user_id
     or run_row.source_code is distinct from new.source_code then
    raise exception 'scope manifest requires its matching running ingestion run';
  end if;
  return new;
end;
$$;

drop trigger if exists ingestion_run_scopes_guard_v031
  on semantic_private.ingestion_run_scopes;
create trigger ingestion_run_scopes_guard_v031
before insert or update or delete on semantic_private.ingestion_run_scopes
for each row execute function semantic_private.guard_ingestion_scope_v031();

-- Every evidence/membership append takes a key-share lock on the same run row
-- that finalization locks FOR UPDATE. Thus a finalizer sees all committed
-- staging writes, and no late writer can append to a terminal manifest.
create or replace function semantic_private.guard_raw_source_record_run_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
begin
  select * into run_row
  from semantic_private.ingestion_runs
  where id = new.ingestion_run_id
  for key share;
  if not found
     or run_row.status <> 'running'
     or run_row.user_id is distinct from new.user_id
     or run_row.source_code is distinct from new.source_code then
    raise exception 'raw records may only be appended to their running ingestion run';
  end if;
  return new;
end;
$$;

drop trigger if exists raw_source_records_guard_run_v031
  on semantic_private.raw_source_records;
create trigger raw_source_records_guard_run_v031
before insert on semantic_private.raw_source_records
for each row execute function semantic_private.guard_raw_source_record_run_v031();

create or replace function semantic_private.guard_observation_ingestion_run()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
begin
  select * into run_row
  from semantic_private.ingestion_runs
  where id = new.ingestion_run_id
  for key share;
  if not found
     or run_row.status <> 'running'
     or run_row.user_id is distinct from new.user_id
     or run_row.source_code is distinct from new.source_code then
    raise exception 'observations may only be appended to their running ingestion run';
  end if;
  return new;
end;
$$;

create or replace function semantic_private.guard_ingestion_run_item_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
  scope_row semantic_private.ingestion_run_scopes%rowtype;
  raw_row semantic_private.raw_source_records%rowtype;
  observation_row semantic_private.observations%rowtype;
begin
  if tg_op <> 'INSERT' then
    raise exception 'ingestion run membership is append-only';
  end if;
  select * into run_row
  from semantic_private.ingestion_runs
  where id = new.ingestion_run_id
  for key share;
  if not found
     or run_row.status <> 'running'
     or run_row.user_id is distinct from new.user_id
     or run_row.source_code is distinct from new.source_code then
    raise exception 'run membership requires its matching running ingestion run';
  end if;
  select * into scope_row
  from semantic_private.ingestion_run_scopes
  where ingestion_run_id = new.ingestion_run_id
    and scope_key = new.scope_key
  for key share;
  if not found
     or scope_row.user_id is distinct from new.user_id
     or scope_row.source_code is distinct from new.source_code then
    raise exception 'run item must match its immutable scope manifest';
  end if;
  if new.raw_source_record_id is not null then
    select * into raw_row
    from semantic_private.raw_source_records
    where id = new.raw_source_record_id and user_id = new.user_id;
    if not found
       or raw_row.source_code is distinct from new.source_code
       or raw_row.data_type is distinct from scope_row.data_type
       or raw_row.source_item_hmac is distinct from new.source_item_hmac
       or raw_row.record_fingerprint is distinct from new.record_fingerprint then
      raise exception 'run item raw evidence does not match its source identity';
    end if;
  end if;
  if new.observation_id is not null then
    select * into observation_row
    from semantic_private.observations
    where id = new.observation_id and user_id = new.user_id;
    if not found
       or observation_row.source_code is distinct from new.source_code
       or observation_row.data_type is distinct from scope_row.data_type
       or observation_row.action_type is distinct from scope_row.action_type
       or observation_row.source_item_hmac is distinct from new.source_item_hmac
       or observation_row.record_fingerprint is distinct from new.record_fingerprint then
      raise exception 'run item observation does not match its source identity';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists ingestion_run_items_guard_v031
  on semantic_private.ingestion_run_items;
create trigger ingestion_run_items_guard_v031
before insert or update or delete on semantic_private.ingestion_run_items
for each row execute function semantic_private.guard_ingestion_run_item_v031();

create or replace function semantic_private.guard_current_source_item_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(
       current_setting('written.finalize_ingestion_v031', true), '0'
     ) <> '1' then
    raise exception 'current source state may change only through the atomic finalizer';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists current_source_items_guard_v031
  on semantic_private.current_source_items;
create trigger current_source_items_guard_v031
before insert or update or delete on semantic_private.current_source_items
for each row execute function semantic_private.guard_current_source_item_v031();

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
    where item.current_observation_id = target_observation_id
      and item.user_id = target_user_id
      and item.lifecycle_state = 'present'
  );
$$;

create or replace function semantic_private.guard_mapping_current_source_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.mapping_state in ('candidate', 'accepted')
     and not semantic_private.observation_is_current_v031(
       new.observation_id, new.user_id
     ) then
    raise exception 'candidate or accepted mapping requires a currently present source item';
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mappings_guard_current_source_v031
  on semantic_private.observation_mappings;
create trigger observation_mappings_guard_current_source_v031
before insert or update of mapping_state, observation_id, user_id
on semantic_private.observation_mappings
for each row execute function semantic_private.guard_mapping_current_source_v031();

-- Legacy triggers used run completion and each observation lifecycle edit as
-- independent semantic changes. During atomic finalization they must be
-- suppressed; the finalizer owns the single revision advance.
create or replace function semantic_private.bump_user_state_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(
       current_setting('written.finalize_ingestion_v031', true), '0'
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
      and head.source_code = run_row.source_code
      and head.latest_run_id is null
      and exists (
        select 1 from semantic_private.ingestion_run_scopes as scope
        where scope.ingestion_run_id = run_row.id
          and scope.scope_key = head.scope_key
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
  update semantic_private.source_state_heads
  set latest_run_started_at = run_row.started_at,
      latest_run_id = run_row.id,
      current_revision = new_revision,
      updated_at = now()
  where user_id = run_row.user_id
    and source_code = run_row.source_code
    and scope_key in (
      select scope.scope_key
      from semantic_private.ingestion_run_scopes as scope
      where scope.ingestion_run_id = run_row.id
    );
  perform set_config('written.finalize_ingestion_v031', '0', true);
  return receipt;
end;
$$;

create or replace function semantic_private.fail_ingestion_run_v031(
  target_ingestion_run_id uuid,
  target_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
  failure_receipt jsonb;
begin
  if target_ingestion_run_id is null
     or target_error_code is null
     or target_error_code !~ '^[a-z][a-z0-9_]{0,63}$' then
    raise exception 'failed ingestion run requires an allowlisted-style error code';
  end if;
  select * into run_row
  from semantic_private.ingestion_runs
  where id = target_ingestion_run_id
  for update;
  if not found then
    raise exception 'ingestion run not found';
  end if;
  if run_row.status = 'failed' then
    if run_row.error_code is distinct from target_error_code then
      raise exception 'terminal ingestion failure code is immutable';
    end if;
    return jsonb_build_object(
      'ingestion_run_id', run_row.id::text,
      'status', 'failed',
      'error_code', run_row.error_code,
      'state_changed', false
    );
  end if;
  if run_row.status <> 'running' then
    raise exception 'only a running ingestion run can fail';
  end if;
  update semantic_private.ingestion_runs
  set status = 'failed', finished_at = now(), error_code = target_error_code
  where id = run_row.id;
  failure_receipt := jsonb_build_object(
    'ingestion_run_id', run_row.id::text,
    'status', 'failed',
    'error_code', target_error_code,
    'state_changed', false
  );
  return failure_receipt;
end;
$$;

-- -------------------------------------------------------------------------
-- Exact score/revision binding for facts that may reach another user.
-- -------------------------------------------------------------------------

drop trigger if exists validated_surface_facts_guard_permission
  on semantic_private.validated_surface_facts;
drop trigger if exists validated_surface_facts_guard_healthkit
  on semantic_private.validated_surface_facts;

drop table if exists pg_temp.surface_fact_v031_upgrade_state;
create temporary table surface_fact_v031_upgrade_state on commit drop as
select count(*) = 2 as columns_preexisting
from information_schema.columns
where table_schema = 'semantic_private'
  and table_name = 'validated_surface_facts'
  and column_name in ('assertion_score_version_id', 'attested_revision');

alter table semantic_private.validated_surface_facts
  add column if not exists assertion_score_version_id uuid,
  add column if not exists attested_revision bigint;

-- Pre-006 facts have no attestation proving which score/revision was reviewed.
-- Never infer that provenance during upgrade; retire and regenerate them.
update semantic_private.validated_surface_facts as fact
set state = 'retired', may_name = false, may_explain = false
where not (
    select columns_preexisting
    from surface_fact_v031_upgrade_state
  );

alter table semantic_private.validated_surface_facts
  drop constraint if exists validated_surface_facts_assertion_id_surface_fact_version_key,
  drop constraint if exists validated_surface_facts_score_v031_fkey,
  add constraint validated_surface_facts_score_v031_fkey
    foreign key (assertion_score_version_id, user_id, assertion_id)
    references semantic_private.assertion_score_versions(id, user_id, assertion_id)
    on delete no action deferrable initially deferred,
  drop constraint if exists validated_surface_facts_revision_v031_check,
  add constraint validated_surface_facts_revision_v031_check check (
    attested_revision is null or attested_revision >= 0
  ),
  drop constraint if exists validated_surface_facts_binding_v031_check,
  add constraint validated_surface_facts_binding_v031_check check (
    state = 'retired'
    or (
      attested_revision is not null
      and (
        assertion_score_version_id is not null
        or confirmation_state in ('user_confirmed', 'explicit_self_report')
      )
    )
  );

create unique index if not exists validated_surface_facts_scored_identity_v031_idx
  on semantic_private.validated_surface_facts (
    assertion_id, surface, fact_version, attested_revision,
    assertion_score_version_id
  ) where assertion_score_version_id is not null;
create unique index if not exists validated_surface_facts_explicit_identity_v031_idx
  on semantic_private.validated_surface_facts (
    assertion_id, surface, fact_version, attested_revision
  ) where assertion_score_version_id is null;

create or replace function semantic_private.surface_fact_binding_is_current_v031(
  target_assertion_id uuid,
  target_user_id uuid,
  target_score_version_id uuid,
  target_attested_revision bigint
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select
      assertion.machine_state not in ('inactive', 'expired')
      and state.revision = target_attested_revision
      and (
        (
          assertion.assertion_origin = 'inferred'
          and target_score_version_id is not null
          and current_score.assertion_score_version_id = target_score_version_id
          and score.id = target_score_version_id
          and score.assertion_id = assertion.id
          and score.user_id = assertion.user_id
          and score.ontology_version_id = assertion.created_ontology_version_id
          and score_run.id = score.semantic_run_id
          and score_run.user_id = assertion.user_id
          and score_run.input_revision = target_attested_revision
          and score_run.status = 'succeeded'
        ) or (
          assertion.assertion_origin in (
            'explicit_addition', 'explicit_self_report'
          )
          and target_score_version_id is null
        )
      )
    from semantic_private.user_assertions as assertion
    join semantic_private.user_state_versions as state
      on state.user_id = assertion.user_id
    left join semantic_private.assertion_current_scores as current_score
      on current_score.assertion_id = assertion.id
     and current_score.user_id = assertion.user_id
    left join semantic_private.assertion_score_versions as score
      on score.id = target_score_version_id
     and score.assertion_id = assertion.id
     and score.user_id = assertion.user_id
    left join semantic_private.semantic_runs as score_run
      on score_run.id = score.semantic_run_id
     and score_run.user_id = score.user_id
    where assertion.id = target_assertion_id
      and assertion.user_id = target_user_id
  ), false);
$$;

create or replace function semantic_private.validated_surface_fact_is_current(
  target_fact_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select fact.state = 'validated'
       and semantic_private.surface_fact_binding_is_current_v031(
         fact.assertion_id, fact.user_id,
         fact.assertion_score_version_id, fact.attested_revision
       )
       and permission.can_select
       and (not fact.may_name or permission.can_name)
       and (not fact.may_explain or permission.can_explain)
    from semantic_private.validated_surface_facts as fact
    join semantic_private.assertion_surface_permissions as permission
      on permission.assertion_id = fact.assertion_id
     and permission.user_id = fact.user_id
     and permission.surface = fact.surface
    where fact.id = target_fact_id
  ), false);
$$;

create or replace function semantic_private.guard_validated_surface_fact()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  assertion_row semantic_private.user_assertions%rowtype;
  score_version uuid;
  permission semantic_private.assertion_surface_permissions%rowtype;
begin
  if tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id
       or new.assertion_id is distinct from old.assertion_id
       or new.ontology_version_id is distinct from old.ontology_version_id
       or new.surface is distinct from old.surface
       or new.predicate_key is distinct from old.predicate_key
       or new.evidence_class is distinct from old.evidence_class
       or new.confirmation_state is distinct from old.confirmation_state
       or new.validator_model_id is distinct from old.validator_model_id
       or new.fact_version is distinct from old.fact_version
       or new.fact_payload is distinct from old.fact_payload
       or new.data_use_purpose is distinct from old.data_use_purpose
       or new.assertion_score_version_id is distinct from old.assertion_score_version_id
       or new.attested_revision is distinct from old.attested_revision
       or new.created_at is distinct from old.created_at then
      raise exception 'surface fact identity, provenance, score, and revision are immutable';
    end if;
    if old.state = 'retired' and (
         new.state <> 'retired' or new.may_name or new.may_explain
       ) then
      raise exception 'retired surface facts are terminal';
    end if;
    -- A rights-only narrowing is always safe, including while a broader
    -- permission row is itself being narrowed by a BEFORE trigger.
    if new.state = old.state
       and (not new.may_name or old.may_name)
       and (not new.may_explain or old.may_explain)
       and (
         new.may_name is distinct from old.may_name
         or new.may_explain is distinct from old.may_explain
       ) then
      return new;
    end if;
  end if;
  if new.state = 'retired' then
    if new.may_name or new.may_explain then
      raise exception 'retired surface facts cannot retain naming or explanation rights';
    end if;
    return new;
  end if;

  select * into assertion_row
  from semantic_private.user_assertions
  where id = new.assertion_id and user_id = new.user_id;
  if not found
     or assertion_row.predicate_key is distinct from new.predicate_key
     or assertion_row.created_ontology_version_id is distinct from new.ontology_version_id then
    raise exception 'surface fact must preserve assertion predicate and version';
  end if;
  if assertion_row.assertion_origin = 'inferred'
     and new.assertion_score_version_id is null then
    raise exception 'inferred surface facts require an exact assertion score version';
  end if;
  if assertion_row.assertion_origin <> 'inferred'
     and new.assertion_score_version_id is not null then
    raise exception 'explicit surface facts use the nullable-score attestation branch';
  end if;
  if not semantic_private.surface_fact_binding_is_current_v031(
       new.assertion_id, new.user_id,
       new.assertion_score_version_id, new.attested_revision
     ) then
    raise exception 'surface fact score and attested revision must be exactly current';
  end if;
  if new.assertion_score_version_id is not null then
    select score.ontology_version_id into score_version
    from semantic_private.assertion_score_versions as score
    where score.id = new.assertion_score_version_id
      and score.assertion_id = new.assertion_id
      and score.user_id = new.user_id;
    if score_version is distinct from new.ontology_version_id then
      raise exception 'surface fact score ontology must match its assertion version';
    end if;
  end if;
  select * into permission
  from semantic_private.assertion_surface_permissions
  where assertion_id = new.assertion_id
    and user_id = new.user_id
    and surface = new.surface;
  if not found or not permission.can_select
     or (new.may_name and not permission.can_name)
     or (new.may_explain and not permission.can_explain) then
    raise exception 'surface fact exceeds assertion surface permission';
  end if;
  if new.evidence_class = 'youtube_derived' and (
       not semantic_private.assertion_has_youtube_evidence(new.assertion_id, new.user_id)
       or (new.may_name and not semantic_private.youtube_assertion_gate_allowed(
         new.assertion_id, new.user_id, new.surface
       ))
       or (new.may_explain and not semantic_private.youtube_assertion_gate_allowed(
         new.assertion_id, new.user_id, 'explanation'
       ))
     ) then
    raise exception 'YouTube-derived fact exceeds its approved run policy';
  end if;
  return new;
end;
$$;

update semantic_private.validated_surface_facts as fact
set state = 'retired', may_name = false, may_explain = false
where fact.state <> 'retired'
  and not semantic_private.surface_fact_binding_is_current_v031(
    fact.assertion_id, fact.user_id,
    fact.assertion_score_version_id, fact.attested_revision
  );

-- A retired fact may already be linked into a ready product. Retiring the
-- cache row is not sufficient: legacy consumers select the materialized
-- product state directly. Run this after every upgrade-time retirement so
-- replay and partially upgraded schemas fail closed as well. Exposed
-- icebreakers remain immutable history.
update semantic_private.bio_variants as bio
set state = 'stale', finalized_at = coalesce(finalized_at, now())
where bio.state in ('draft', 'ready')
  and exists (
    select 1
    from semantic_private.bio_variant_facts as link
    join semantic_private.validated_surface_facts as fact
      on fact.id = link.surface_fact_id
     and fact.user_id = link.subject_user_id
    where link.bio_variant_id = bio.id
      and fact.state = 'retired'
  );
update semantic_private.icebreaker_frames as frame
set state = 'stale', finalized_at = coalesce(finalized_at, now())
where frame.state in ('draft', 'ready')
  and frame.exposed_at is null
  and exists (
    select 1
    from semantic_private.icebreaker_frame_facts as link
    join semantic_private.validated_surface_facts as fact
      on fact.id = link.surface_fact_id
     and fact.user_id = link.fact_user_id
    where link.icebreaker_frame_id = frame.id
      and fact.state = 'retired'
  );

create trigger validated_surface_facts_guard_permission
before insert or update on semantic_private.validated_surface_facts
for each row execute function semantic_private.guard_validated_surface_fact();

create trigger validated_surface_facts_guard_healthkit
before insert or update on semantic_private.validated_surface_facts
for each row execute function semantic_private.guard_healthkit_surface_fact();

create or replace function semantic_private.guard_surface_fact_link_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  fact_id uuid;
  expected_surface text;
begin
  if tg_table_name = 'bio_variant_facts' then
    fact_id := new.surface_fact_id;
    expected_surface := 'bio';
  else
    fact_id := new.surface_fact_id;
    expected_surface := 'icebreaker';
  end if;
  if not exists (
    select 1
    from semantic_private.validated_surface_facts as fact
    where fact.id = fact_id
      and fact.surface = expected_surface
      and fact.state = 'validated'
      and fact.may_name
      and semantic_private.validated_surface_fact_is_current(fact.id)
  ) then
    raise exception 'product link requires a current validated nameable surface fact';
  end if;
  return new;
end;
$$;

drop trigger if exists bio_variant_facts_guard_current_v031
  on semantic_private.bio_variant_facts;
create trigger bio_variant_facts_guard_current_v031
before insert or update on semantic_private.bio_variant_facts
for each row execute function semantic_private.guard_surface_fact_link_v031();

drop trigger if exists icebreaker_frame_facts_guard_current_v031
  on semantic_private.icebreaker_frame_facts;
create trigger icebreaker_frame_facts_guard_current_v031
before insert or update on semantic_private.icebreaker_frame_facts
for each row execute function semantic_private.guard_surface_fact_link_v031();

create or replace function semantic_private.active_match_authorization_id_v031(
  first_user_id uuid,
  second_user_id uuid
)
returns uuid
language sql
stable
set search_path = ''
as $$
  select authz.id
  from semantic_private.match_authorizations as authz
  where authz.authorization_state = 'active'
    and (
      (
        authz.participant_a_user_id = first_user_id
        and authz.participant_b_user_id = second_user_id
      ) or (
        authz.participant_a_user_id = second_user_id
        and authz.participant_b_user_id = first_user_id
      )
    )
  order by authz.authorized_at desc, authz.id
  limit 1;
$$;

create or replace function semantic_private.guard_bio_variant_ready()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  invalid_fact_count integer;
  fact_count integer;
begin
  if new.state <> 'ready' then return new; end if;
  if not semantic_private.dyad_run_is_current(new.dyad_run_id) then
    raise exception 'ready bio requires both current user revisions';
  end if;
  if semantic_private.active_match_authorization_id_v031(
       new.viewer_user_id, new.subject_user_id
     ) is null then
    raise exception 'ready bio requires a current social authorization';
  end if;
  select count(*), count(*) filter (
    where fact.surface <> 'bio'
       or fact.state <> 'validated'
       or not fact.may_name
       or fact.user_id <> new.subject_user_id
       or not semantic_private.validated_surface_fact_is_current(fact.id)
  ) into fact_count, invalid_fact_count
  from semantic_private.bio_variant_facts as link
  join semantic_private.validated_surface_facts as fact
    on fact.id = link.surface_fact_id
   and fact.user_id = link.subject_user_id
  where link.bio_variant_id = new.id;
  if fact_count < 1 or invalid_fact_count > 0 then
    raise exception 'ready bio requires current validated nameable subject facts';
  end if;
  return new;
end;
$$;

drop trigger if exists bio_variants_guard_ready on semantic_private.bio_variants;
create trigger bio_variants_guard_ready
before insert or update of state, dyad_run_id on semantic_private.bio_variants
for each row execute function semantic_private.guard_bio_variant_ready();

-- -------------------------------------------------------------------------
-- Permission narrowing is an invalidation event for every lattice bit.
-- DELETE is deliberately equivalent to replacing the row with all-false.
-- -------------------------------------------------------------------------

drop trigger if exists assertion_permissions_invalidate_matching_outputs
  on semantic_private.assertion_surface_permissions;

create or replace function semantic_private.guard_healthkit_surface_permission()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Revocation and rights narrowing must remain possible even after the
  -- underlying fitness candidate or grant has gone stale.
  if tg_op = 'UPDATE'
     and (not new.can_select or old.can_select)
     and (not new.can_name or old.can_name)
     and (not new.can_explain or old.can_explain)
     and (
       new.can_select is distinct from old.can_select
       or new.can_name is distinct from old.can_name
       or new.can_explain is distinct from old.can_explain
     ) then
    return new;
  end if;
  if not semantic_private.assertion_has_healthkit_evidence(
       new.assertion_id, new.user_id
     ) then
    return new;
  end if;
  if (new.can_select or new.can_name or new.can_explain)
     and not semantic_private.healthkit_assertion_is_current(
       new.assertion_id, new.user_id
     ) then
    raise exception 'stale HealthKit assertion cannot receive surface permission';
  end if;
  if new.can_select and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'select'
     ) then
    raise exception 'HealthKit assertion exceeds its fitness-purpose grant';
  end if;
  if new.can_name and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'name'
     ) then
    raise exception 'HealthKit assertion naming is not granted';
  end if;
  if new.can_explain and not semantic_private.healthkit_grant_allows(
       new.user_id, new.surface, 'explain'
     ) then
    raise exception 'HealthKit assertion explanation is not granted';
  end if;
  return new;
end;
$$;

create or replace function semantic_private.invalidate_on_surface_permission_narrowing_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  next_can_select boolean;
  next_can_name boolean;
  next_can_explain boolean;
  narrowed_select boolean;
  narrowed_name boolean;
  narrowed_explain boolean;
begin
  if tg_op = 'UPDATE' and (
       new.assertion_id is distinct from old.assertion_id
       or new.user_id is distinct from old.user_id
       or new.surface is distinct from old.surface
     ) then
    raise exception 'assertion surface permission identity is immutable';
  end if;
  next_can_select := case when tg_op = 'DELETE' then false else new.can_select end;
  next_can_name := case when tg_op = 'DELETE' then false else new.can_name end;
  next_can_explain := case when tg_op = 'DELETE' then false else new.can_explain end;
  narrowed_select := old.can_select and not next_can_select;
  narrowed_name := old.can_name and not next_can_name;
  narrowed_explain := old.can_explain and not next_can_explain;
  if not (narrowed_select or narrowed_name or narrowed_explain) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if old.surface = 'matching' and narrowed_select then
    update semantic_private.dyad_runs
    set status = 'stale', finished_at = coalesce(finished_at, now())
    where (viewer_user_id = old.user_id or subject_user_id = old.user_id)
      and status in ('running', 'succeeded');
    update semantic_private.bio_variants as bio
    set state = 'stale', finalized_at = coalesce(finalized_at, now())
    where bio.state in ('draft', 'ready')
      and exists (
        select 1 from semantic_private.dyad_runs as run
        where run.id = bio.dyad_run_id and run.status = 'stale'
      );
    update semantic_private.icebreaker_frames as frame
    set state = 'stale', finalized_at = coalesce(finalized_at, now())
    where frame.state in ('draft', 'ready')
      and frame.exposed_at is null
      and exists (
        select 1 from semantic_private.dyad_runs as run
        where run.id = frame.dyad_run_id and run.status = 'stale'
      );
  elsif old.surface = 'bio' then
    if narrowed_select or narrowed_name then
      update semantic_private.validated_surface_facts
      set state = 'retired', may_name = false, may_explain = false
      where assertion_id = old.assertion_id
        and user_id = old.user_id
        and surface = 'bio'
        and state <> 'retired';
    elsif narrowed_explain then
      update semantic_private.validated_surface_facts
      set may_explain = false
      where assertion_id = old.assertion_id
        and user_id = old.user_id
        and surface = 'bio'
        and may_explain;
    end if;
    update semantic_private.bio_variants as bio
    set state = 'stale', finalized_at = coalesce(finalized_at, now())
    where bio.state in ('draft', 'ready')
      and exists (
        select 1
        from semantic_private.bio_variant_facts as link
        join semantic_private.validated_surface_facts as fact
          on fact.id = link.surface_fact_id
         and fact.user_id = link.subject_user_id
        where link.bio_variant_id = bio.id
          and fact.assertion_id = old.assertion_id
          and fact.user_id = old.user_id
      );
  elsif old.surface = 'icebreaker' then
    if narrowed_select or narrowed_name then
      update semantic_private.validated_surface_facts
      set state = 'retired', may_name = false, may_explain = false
      where assertion_id = old.assertion_id
        and user_id = old.user_id
        and surface = 'icebreaker'
        and state <> 'retired';
    elsif narrowed_explain then
      update semantic_private.validated_surface_facts
      set may_explain = false
      where assertion_id = old.assertion_id
        and user_id = old.user_id
        and surface = 'icebreaker'
        and may_explain;
    end if;
    update semantic_private.icebreaker_frames as frame
    set state = 'stale', finalized_at = coalesce(finalized_at, now())
    where frame.state in ('draft', 'ready')
      and frame.exposed_at is null
      and exists (
        select 1
        from semantic_private.icebreaker_frame_facts as link
        join semantic_private.validated_surface_facts as fact
          on fact.id = link.surface_fact_id
         and fact.user_id = link.fact_user_id
        where link.icebreaker_frame_id = frame.id
          and fact.assertion_id = old.assertion_id
          and fact.user_id = old.user_id
      );
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists assertion_permissions_invalidate_outputs_v031
  on semantic_private.assertion_surface_permissions;
create trigger assertion_permissions_invalidate_outputs_v031
before update or delete on semantic_private.assertion_surface_permissions
for each row execute function semantic_private.invalidate_on_surface_permission_narrowing_v031();

-- -------------------------------------------------------------------------
-- Terminal authorization epochs and exposure/revocation serialization.
-- -------------------------------------------------------------------------

alter table semantic_private.match_authorizations
  add column if not exists authorization_epoch bigint not null default 1,
  add column if not exists revocation_reason_code text;

update semantic_private.match_authorizations
set revocation_reason_code = 'legacy_unspecified'
where authorization_state <> 'active'
  and revocation_reason_code is null;

alter table semantic_private.match_authorizations
  drop constraint if exists match_authorizations_match_id_key,
  drop constraint if exists match_authorizations_epoch_v031_check,
  add constraint match_authorizations_epoch_v031_check check (
    authorization_epoch > 0
  ),
  drop constraint if exists match_authorizations_reason_v031_check,
  add constraint match_authorizations_reason_v031_check check (
    (authorization_state = 'active' and revocation_reason_code is null)
    or (
      authorization_state <> 'active'
      and revocation_reason_code ~ '^[a-z][a-z0-9_]{0,63}$'
    )
  );

create unique index if not exists match_authorizations_epoch_v031_idx
  on semantic_private.match_authorizations (match_id, authorization_epoch);
create unique index if not exists match_authorizations_one_active_v031_idx
  on semantic_private.match_authorizations (match_id)
  where authorization_state = 'active';
create unique index if not exists match_authorizations_one_active_pair_v031_idx
  on semantic_private.match_authorizations (
    least(participant_a_user_id, participant_b_user_id),
    greatest(participant_a_user_id, participant_b_user_id)
  ) where authorization_state = 'active';

create or replace function semantic_private.guard_match_authorization_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  prior_row semantic_private.match_authorizations%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.authorization_state <> 'active'
       or new.revoked_at is not null
       or new.revocation_reason_code is not null then
      raise exception 'a new match authorization epoch must start active';
    end if;
    select * into prior_row
    from semantic_private.match_authorizations
    where match_id = new.match_id
    order by authorization_epoch desc
    limit 1;
    if found then
      if not (
           (
             prior_row.participant_a_user_id = new.participant_a_user_id
             and prior_row.participant_b_user_id = new.participant_b_user_id
           ) or (
             prior_row.participant_a_user_id = new.participant_b_user_id
             and prior_row.participant_b_user_id = new.participant_a_user_id
           )
         ) then
        raise exception 'authorization epochs cannot change match participants';
      end if;
      if new.authorization_epoch <> prior_row.authorization_epoch + 1 then
        raise exception 'new authorization epoch must follow the terminal prior epoch';
      end if;
    elsif new.authorization_epoch <> 1 then
      raise exception 'the first authorization epoch must be one';
    end if;
    return new;
  end if;
  if new.match_id is distinct from old.match_id
     or new.participant_a_user_id is distinct from old.participant_a_user_id
     or new.participant_b_user_id is distinct from old.participant_b_user_id
     or new.authorization_epoch is distinct from old.authorization_epoch
     or new.authorized_at is distinct from old.authorized_at
     or new.source_version is distinct from old.source_version
     or new.created_at is distinct from old.created_at then
    raise exception 'match authorization identity, epoch, and participants are immutable';
  end if;
  if old.authorization_state <> 'active' and new is distinct from old then
    raise exception 'revoked or expired match authorization epochs are terminal';
  end if;
  if old.authorization_state = 'active'
     and new.authorization_state = 'active'
     and new is distinct from old then
    raise exception 'active authorization identity cannot be edited in place';
  end if;
  if old.authorization_state = 'active'
     and new.authorization_state not in ('revoked', 'expired') then
    raise exception 'authorization may only transition from active to a terminal state';
  end if;
  return new;
end;
$$;

drop trigger if exists match_authorizations_guard_identity
  on semantic_private.match_authorizations;
create trigger match_authorizations_guard_identity
before insert or update on semantic_private.match_authorizations
for each row execute function semantic_private.guard_match_authorization_identity();

create or replace function semantic_private.invalidate_on_match_revocation_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.authorization_state = 'active'
     and new.authorization_state in ('revoked', 'expired') then
    update semantic_private.icebreaker_frames
    set state = 'revoked', finalized_at = coalesce(finalized_at, now())
    where match_authorization_id = new.id
      and exposed_at is null
      and state in ('draft', 'ready', 'stale');
    update semantic_private.dyad_runs
    set status = 'stale', finished_at = coalesce(finished_at, now())
    where (
      viewer_user_id in (
        new.participant_a_user_id, new.participant_b_user_id
      )
      and subject_user_id in (
        new.participant_a_user_id, new.participant_b_user_id
      )
    ) and status in ('running', 'succeeded');
    update semantic_private.bio_variants as bio
    set state = 'stale', finalized_at = coalesce(finalized_at, now())
    where bio.state in ('draft', 'ready')
      and exists (
        select 1 from semantic_private.dyad_runs as run
        where run.id = bio.dyad_run_id and run.status = 'stale'
      );
  end if;
  return new;
end;
$$;

drop trigger if exists match_authorizations_invalidate_v031
  on semantic_private.match_authorizations;
create trigger match_authorizations_invalidate_v031
after update of authorization_state on semantic_private.match_authorizations
for each row execute function semantic_private.invalidate_on_match_revocation_v031();

create or replace function semantic_private.revoke_match_authorization_v031(
  target_match_id uuid,
  reason_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  authorization_row semantic_private.match_authorizations%rowtype;
begin
  if target_match_id is null
     or reason_code is null
     or reason_code !~ '^[a-z][a-z0-9_]{0,63}$' then
    raise exception 'match id and tokenized revocation reason are required';
  end if;
  select * into authorization_row
  from semantic_private.match_authorizations
  where match_id = target_match_id and authorization_state = 'active'
  order by authorization_epoch desc
  limit 1
  for update;
  if not found then
    select * into authorization_row
    from semantic_private.match_authorizations
    where match_id = target_match_id
    order by authorization_epoch desc
    limit 1
    for update;
    if not found then
      raise exception 'match authorization not found';
    end if;
    return jsonb_build_object(
      'match_id', authorization_row.match_id::text,
      'authorization_id', authorization_row.id::text,
      'authorization_epoch', authorization_row.authorization_epoch,
      'authorization_state', authorization_row.authorization_state,
      'revocation_reason_code', authorization_row.revocation_reason_code
    );
  end if;
  update semantic_private.match_authorizations
  set authorization_state = 'revoked', revoked_at = now(),
      revocation_reason_code = reason_code
  where id = authorization_row.id
  returning * into authorization_row;
  return jsonb_build_object(
    'match_id', authorization_row.match_id::text,
    'authorization_id', authorization_row.id::text,
    'authorization_epoch', authorization_row.authorization_epoch,
    'authorization_state', authorization_row.authorization_state,
    'revocation_reason_code', authorization_row.revocation_reason_code
  );
end;
$$;

create or replace function semantic_private.dyad_run_is_current(target_run_id uuid)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select coalesce((
    select run.viewer_revision = coalesce(viewer_state.revision, 0)
       and run.subject_revision = coalesce(subject_state.revision, 0)
       and run.status in ('running', 'succeeded')
       and semantic_private.active_match_authorization_id_v031(
         run.viewer_user_id, run.subject_user_id
       ) is not null
       and not exists (
         select 1
         from semantic_private.dyad_alignment_pairs as pair
         where pair.dyad_run_id = run.id
           and (
             (
               semantic_private.assertion_has_healthkit_evidence(
                 pair.viewer_assertion_id, pair.viewer_user_id
               )
               and not semantic_private.healthkit_assertion_is_current(
                 pair.viewer_assertion_id, pair.viewer_user_id
               )
             ) or (
               semantic_private.assertion_has_healthkit_evidence(
                 pair.subject_assertion_id, pair.subject_user_id
               )
               and not semantic_private.healthkit_assertion_is_current(
                 pair.subject_assertion_id, pair.subject_user_id
               )
             )
           )
       )
    from semantic_private.dyad_runs as run
    left join semantic_private.user_state_versions as viewer_state
      on viewer_state.user_id = run.viewer_user_id
    left join semantic_private.user_state_versions as subject_state
      on subject_state.user_id = run.subject_user_id
    where run.id = target_run_id
  ), false);
$$;

create or replace function semantic_private.guard_dyad_run_current()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_viewer_revision bigint;
  current_subject_revision bigint;
begin
  if new.status not in ('running', 'succeeded') then return new; end if;
  select revision into current_viewer_revision
  from semantic_private.user_state_versions where user_id = new.viewer_user_id;
  select revision into current_subject_revision
  from semantic_private.user_state_versions where user_id = new.subject_user_id;
  if new.viewer_revision <> coalesce(current_viewer_revision, 0)
     or new.subject_revision <> coalesce(current_subject_revision, 0) then
    raise exception 'dyad run requires both current user revisions';
  end if;
  if semantic_private.active_match_authorization_id_v031(
       new.viewer_user_id, new.subject_user_id
     ) is null then
    raise exception 'dyad run requires an exact current social authorization';
  end if;
  return new;
end;
$$;

drop trigger if exists dyad_runs_guard_current on semantic_private.dyad_runs;
create trigger dyad_runs_guard_current
before insert or update of status, viewer_revision, subject_revision
on semantic_private.dyad_runs
for each row execute function semantic_private.guard_dyad_run_current();

create or replace function semantic_private.guard_icebreaker_frame_ready()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  auth_row semantic_private.match_authorizations%rowtype;
  run_version uuid;
  viewer_fact semantic_private.validated_surface_facts%rowtype;
  subject_fact semantic_private.validated_surface_facts%rowtype;
begin
  if new.state <> 'ready' then return new; end if;
  if not semantic_private.dyad_run_is_current(new.dyad_run_id) then
    raise exception 'ready icebreaker requires current revisions and authorization';
  end if;
  select * into auth_row
  from semantic_private.match_authorizations
  where id = new.match_authorization_id;
  if not found
     or auth_row.authorization_state <> 'active'
     or not (
       (
         auth_row.participant_a_user_id = new.viewer_user_id
         and auth_row.participant_b_user_id = new.subject_user_id
       ) or (
         auth_row.participant_a_user_id = new.subject_user_id
         and auth_row.participant_b_user_id = new.viewer_user_id
       )
     ) then
    raise exception 'icebreaker requires the exact active match authorization';
  end if;
  select ontology_version_id into run_version
  from semantic_private.dyad_runs where id = new.dyad_run_id;
  if new.ontology_version_id is distinct from run_version then
    raise exception 'icebreaker ontology version must match its dyad run';
  end if;
  select fact.* into viewer_fact
  from semantic_private.icebreaker_frame_facts as link
  join semantic_private.validated_surface_facts as fact
    on fact.id = link.surface_fact_id and fact.user_id = link.fact_user_id
  where link.icebreaker_frame_id = new.id and link.fact_side = 'viewer';
  select fact.* into subject_fact
  from semantic_private.icebreaker_frame_facts as link
  join semantic_private.validated_surface_facts as fact
    on fact.id = link.surface_fact_id and fact.user_id = link.fact_user_id
  where link.icebreaker_frame_id = new.id and link.fact_side = 'subject';
  if viewer_fact.id is null or subject_fact.id is null
     or viewer_fact.user_id is distinct from new.viewer_user_id
     or subject_fact.user_id is distinct from new.subject_user_id
     or viewer_fact.surface <> 'icebreaker'
     or subject_fact.surface <> 'icebreaker'
     or not viewer_fact.may_name
     or not subject_fact.may_name
     or not semantic_private.validated_surface_fact_is_current(viewer_fact.id)
     or not semantic_private.validated_surface_fact_is_current(subject_fact.id) then
    raise exception 'ready icebreaker requires one current validated nameable fact per side';
  end if;
  if new.bridge_mode = 'both_like' and (
    viewer_fact.predicate_key <> 'affinity_to'
    or subject_fact.predicate_key <> 'affinity_to'
    or viewer_fact.confirmation_state not in ('user_confirmed', 'explicit_self_report')
    or subject_fact.confirmation_state not in ('user_confirmed', 'explicit_self_report')
  ) then
    raise exception 'both_like requires two confirmed affinity facts';
  end if;
  return new;
end;
$$;

drop trigger if exists icebreaker_frames_guard_ready
  on semantic_private.icebreaker_frames;
create trigger icebreaker_frames_guard_ready
before insert or update of state, dyad_run_id, match_authorization_id
on semantic_private.icebreaker_frames
for each row execute function semantic_private.guard_icebreaker_frame_ready();

create or replace function semantic_private.bio_variant_is_current_v031(
  target_bio_variant_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select bio.state = 'ready'
       and semantic_private.dyad_run_is_current(bio.dyad_run_id)
       and semantic_private.active_match_authorization_id_v031(
         bio.viewer_user_id, bio.subject_user_id
       ) is not null
       and exists (
         select 1 from semantic_private.bio_variant_facts as link
         where link.bio_variant_id = bio.id
       )
       and not exists (
         select 1
         from semantic_private.bio_variant_facts as link
         where link.bio_variant_id = bio.id
           and not semantic_private.validated_surface_fact_is_current(
             link.surface_fact_id
           )
       )
    from semantic_private.bio_variants as bio
    where bio.id = target_bio_variant_id
  ), false);
$$;

create or replace function semantic_private.icebreaker_frame_is_current_candidate_v031(
  target_frame_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select frame.state = 'ready'
       and frame.exposed_at is null
       and frame.rendered_text is not null
       and authz.authorization_state = 'active'
       and semantic_private.dyad_run_is_current(frame.dyad_run_id)
       and 2 = (
         select count(*)
         from semantic_private.icebreaker_frame_facts as link
         where link.icebreaker_frame_id = frame.id
       )
       and not exists (
         select 1
         from semantic_private.icebreaker_frame_facts as link
         where link.icebreaker_frame_id = frame.id
           and not semantic_private.validated_surface_fact_is_current(
             link.surface_fact_id
           )
       )
    from semantic_private.icebreaker_frames as frame
    join semantic_private.match_authorizations as authz
      on authz.id = frame.match_authorization_id
    where frame.id = target_frame_id
  ), false);
$$;

create or replace function semantic_private.mark_icebreaker_exposed(target_frame_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  frame_row semantic_private.icebreaker_frames%rowtype;
  authorization_row semantic_private.match_authorizations%rowtype;
  authorization_id_value uuid;
begin
  select match_authorization_id into authorization_id_value
  from semantic_private.icebreaker_frames
  where id = target_frame_id;
  if not found then raise exception 'icebreaker frame not found'; end if;
  select * into authorization_row
  from semantic_private.match_authorizations
  where id = authorization_id_value
  for update;
  if not found then raise exception 'icebreaker authorization not found'; end if;
  select * into frame_row
  from semantic_private.icebreaker_frames
  where id = target_frame_id
  for update;
  if frame_row.match_authorization_id is distinct from authorization_row.id then
    raise exception 'icebreaker authorization changed during first exposure';
  end if;
  if frame_row.exposed_at is not null then
    return;
  end if;
  if authorization_row.authorization_state <> 'active' then
    raise exception 'icebreaker is not currently authorized for first exposure';
  end if;
  if not semantic_private.icebreaker_frame_is_current_candidate_v031(
       target_frame_id
     ) then
    raise exception 'icebreaker is not current and authorized for first exposure';
  end if;
  perform set_config('written.mark_icebreaker_exposed', '1', true);
  update semantic_private.icebreaker_frames
  set exposed_at = now()
  where id = target_frame_id and exposed_at is null;
  if not found then
    raise exception 'icebreaker was already exposed';
  end if;
  perform set_config('written.mark_icebreaker_exposed', '0', true);
end;
$$;

-- Existing dyad products without an active authorization are fail-closed.
update semantic_private.dyad_runs as run
set status = 'stale', finished_at = coalesce(finished_at, now())
where run.status in ('running', 'succeeded')
  and semantic_private.active_match_authorization_id_v031(
    run.viewer_user_id, run.subject_user_id
  ) is null;
update semantic_private.bio_variants as bio
set state = 'stale', finalized_at = coalesce(finalized_at, now())
where bio.state in ('draft', 'ready')
  and exists (
    select 1 from semantic_private.dyad_runs as run
    where run.id = bio.dyad_run_id and run.status = 'stale'
  );
update semantic_private.icebreaker_frames as frame
set state = 'stale', finalized_at = coalesce(finalized_at, now())
where frame.state in ('draft', 'ready')
  and frame.exposed_at is null
  and exists (
    select 1 from semantic_private.dyad_runs as run
    where run.id = frame.dyad_run_id and run.status = 'stale'
  );

create or replace function semantic_private.invalidate_surface_facts_on_score_pointer_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_assertion_id uuid;
  target_user_id uuid;
  current_score_id uuid;
begin
  if tg_op = 'DELETE' then
    target_assertion_id := old.assertion_id;
    target_user_id := old.user_id;
    current_score_id := null;
  else
    target_assertion_id := new.assertion_id;
    target_user_id := new.user_id;
    current_score_id := new.assertion_score_version_id;
  end if;
  update semantic_private.validated_surface_facts
  set state = 'retired', may_name = false, may_explain = false
  where assertion_id = target_assertion_id
    and user_id = target_user_id
    and assertion_score_version_id is not null
    and assertion_score_version_id is distinct from current_score_id
    and state <> 'retired';
  update semantic_private.bio_variants as bio
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where bio.state in ('draft', 'ready')
    and exists (
      select 1
      from semantic_private.bio_variant_facts as link
      join semantic_private.validated_surface_facts as fact
        on fact.id = link.surface_fact_id
       and fact.user_id = link.subject_user_id
      where link.bio_variant_id = bio.id
        and fact.assertion_id = target_assertion_id
        and fact.user_id = target_user_id
        and fact.state = 'retired'
    );
  update semantic_private.icebreaker_frames as frame
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where frame.state in ('draft', 'ready')
    and frame.exposed_at is null
    and exists (
      select 1
      from semantic_private.icebreaker_frame_facts as link
      join semantic_private.validated_surface_facts as fact
        on fact.id = link.surface_fact_id
       and fact.user_id = link.fact_user_id
      where link.icebreaker_frame_id = frame.id
        and fact.assertion_id = target_assertion_id
        and fact.user_id = target_user_id
        and fact.state = 'retired'
    );
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists assertion_current_scores_invalidate_facts_v031
  on semantic_private.assertion_current_scores;
create trigger assertion_current_scores_invalidate_facts_v031
after insert or update or delete
on semantic_private.assertion_current_scores
for each row execute function semantic_private.invalidate_surface_facts_on_score_pointer_v031();

create or replace function semantic_private.invalidate_product_outputs_on_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.revision is not distinct from old.revision then return new; end if;
  update semantic_private.validated_surface_facts
  set state = 'retired', may_name = false, may_explain = false
  where user_id = new.user_id
    and state <> 'retired'
    and attested_revision is distinct from new.revision;
  update semantic_private.fitness_habit_candidates as candidate
  set review_state = 'retired'
  where candidate.user_id = new.user_id
    and candidate.review_state in ('candidate', 'user_confirmed')
    and exists (
      select 1 from semantic_private.fitness_feature_snapshots as snapshot
      where snapshot.id = candidate.feature_snapshot_id
        and snapshot.user_id = candidate.user_id
        and snapshot.input_revision <> new.revision
    );
  update semantic_private.fitness_feature_snapshots
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where user_id = new.user_id
    and input_revision <> new.revision
    and state in ('building', 'ready');
  update semantic_private.memories_snapshots
  set state = 'stale', finished_at = coalesce(finished_at, now())
  where user_id = new.user_id
    and input_revision <> new.revision
    and state in ('building', 'ready');
  update semantic_private.dyad_runs
  set status = 'stale', finished_at = coalesce(finished_at, now())
  where (viewer_user_id = new.user_id or subject_user_id = new.user_id)
    and status in ('running', 'succeeded')
    and (
      (viewer_user_id = new.user_id and viewer_revision <> new.revision) or
      (subject_user_id = new.user_id and subject_revision <> new.revision)
    );
  update semantic_private.bio_variants as bio
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = bio.dyad_run_id and run.status = 'stale'
    );
  update semantic_private.icebreaker_frames as frame
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and frame.exposed_at is null
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = frame.dyad_run_id and run.status = 'stale'
    );
  return new;
end;
$$;

drop trigger if exists user_state_versions_invalidate_product_outputs
  on semantic_private.user_state_versions;
create trigger user_state_versions_invalidate_product_outputs
after update of revision on semantic_private.user_state_versions
for each row execute function semantic_private.invalidate_product_outputs_on_revision();

-- -------------------------------------------------------------------------
-- Default-deny ownership. Only the service role can stage manifests or call
-- the security-definer state-transition entry points. Current pointers and run
-- terminal status are read-only to that role outside those functions.
-- -------------------------------------------------------------------------

alter table semantic_private.ingestion_run_scopes enable row level security;
alter table semantic_private.ingestion_run_items enable row level security;
alter table semantic_private.current_source_items enable row level security;
alter table semantic_private.source_state_heads enable row level security;

revoke all on table
  semantic_private.ingestion_run_scopes,
  semantic_private.ingestion_run_items,
  semantic_private.current_source_items,
  semantic_private.source_state_heads
from public, anon, authenticated, service_role;

grant select, insert on table
  semantic_private.ingestion_run_scopes,
  semantic_private.ingestion_run_items
to service_role;
grant select on table
  semantic_private.current_source_items,
  semantic_private.source_state_heads
to service_role;
revoke update on table semantic_private.ingestion_runs from service_role;

revoke all on function semantic_private.finalize_ingestion_run_v031(uuid)
  from public, anon, authenticated, service_role;
revoke all on function semantic_private.fail_ingestion_run_v031(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function semantic_private.revoke_match_authorization_v031(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function semantic_private.mark_icebreaker_exposed(uuid)
  from public, anon, authenticated, service_role;
grant execute on function semantic_private.finalize_ingestion_run_v031(uuid)
  to service_role;
grant execute on function semantic_private.fail_ingestion_run_v031(uuid, text)
  to service_role;
grant execute on function semantic_private.revoke_match_authorization_v031(uuid, text)
  to service_role;
grant execute on function semantic_private.mark_icebreaker_exposed(uuid)
  to service_role;

revoke all on function semantic_private.guard_ingestion_scope_v031() from public;
revoke all on function semantic_private.guard_raw_source_record_run_v031() from public;
revoke all on function semantic_private.guard_ingestion_run_item_v031() from public;
revoke all on function semantic_private.guard_current_source_item_v031() from public;
revoke all on function semantic_private.observation_is_current_v031(uuid, uuid) from public;
revoke all on function semantic_private.guard_mapping_current_source_v031() from public;
revoke all on function semantic_private.surface_fact_binding_is_current_v031(
  uuid, uuid, uuid, bigint
) from public;
revoke all on function semantic_private.validated_surface_fact_is_current(uuid) from public;
revoke all on function semantic_private.guard_surface_fact_link_v031() from public;
revoke all on function semantic_private.active_match_authorization_id_v031(uuid, uuid)
  from public;
revoke all on function semantic_private.invalidate_on_surface_permission_narrowing_v031()
  from public;
revoke all on function semantic_private.invalidate_on_match_revocation_v031() from public;
revoke all on function semantic_private.bio_variant_is_current_v031(uuid) from public;
revoke all on function semantic_private.icebreaker_frame_is_current_candidate_v031(uuid)
  from public;
revoke all on function semantic_private.invalidate_surface_facts_on_score_pointer_v031()
  from public;

grant execute on function semantic_private.observation_is_current_v031(uuid, uuid),
  semantic_private.surface_fact_binding_is_current_v031(uuid, uuid, uuid, bigint),
  semantic_private.validated_surface_fact_is_current(uuid),
  semantic_private.active_match_authorization_id_v031(uuid, uuid),
  semantic_private.bio_variant_is_current_v031(uuid),
  semantic_private.icebreaker_frame_is_current_candidate_v031(uuid)
to service_role;

commit;
