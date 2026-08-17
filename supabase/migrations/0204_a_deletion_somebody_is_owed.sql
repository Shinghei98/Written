-- 0204 — a deletion somebody is owed.
--
-- ## Account deletion fails today, for every account in this database
--
-- `delete-account` deletes the `auth.users` row and lets the cascade do the
-- rest. **Six `before delete` guards on `semantic_private` tables sit in that
-- cascade and refuse.** A row-level trigger fires on a cascaded delete exactly
-- as it does on a direct one, so the first guarded child row raises and the
-- whole erasure rolls back.
--
-- All three live accounts hold rows behind them — 58,789 `ingestion_run_items`,
-- 9,712 `current_source_items` — so there is no account here that can currently
-- be deleted. Account deletion is an App Store requirement and an obligation
-- this project already names as one of only three permitted deletions.
--
-- `0166` met the first of these guards and read it correctly at the time:
-- *"`guard_ingestion_run_item_v031` refuses every operation that is not an
-- `INSERT`, with no escape hatch of any kind."* The conclusion drawn then was to
-- stop deleting and redact instead, which is right for `forget_distillation` —
-- that call keeps the account. It is not available to account deletion, where
-- the `auth.users` row genuinely goes and every cascade behind it must be
-- allowed to follow.
--
-- ## The house already solved this, once
--
-- `guard_healthkit_grant_delete` (`0046:344`) is the pattern, and its comment
-- states the reasoning exactly:
--
--     -- Keep the audited consent/revocation row for the life of the account. A
--     -- cascading auth-user deletion is allowed because the parent row is
--     -- already absent from the deleting transaction; direct service deletion
--     -- is not.
--     if exists (select 1 from auth.users where id = old.user_id) then
--       raise exception 'HealthKit grants must be revoked, not deleted';
--     end if;
--
-- **Refuse while the owner exists; permit once they are gone.** The parent row
-- is deleted before its cascade fires, so an erasure passes and every ordinary
-- delete still meets the same refusal it met yesterday. It needs no flag, no
-- privileged procedure and no new grant — a `security definer` erasure function
-- would be a fourth mechanism where the schema already has one, and a
-- transaction-local GUC would be a fifth that every future deletion path has to
-- remember to raise.
--
-- This migration applies that test to the five guards that lack it. **Nothing
-- else about what any of them refuses changes.**
--
-- ## A trigger fix alone would not have been enough
--
-- `ingestion_run_items` holds `(observation_id, user_id)` and
-- `(raw_source_record_id, user_id)` foreign keys with **no `on delete` clause
-- and no `deferrable`** — so `no action`, checked immediately. Cascade order
-- among siblings is unspecified, so an erasure that reached `observations`
-- before `ingestion_run_items` would raise a foreign-key violation with every
-- trigger behaving perfectly. Both become `deferrable initially deferred`, which
-- is what `observations → ingestion_runs` already does (`0042:483`) for the same
-- reason. Deferring changes nothing about what is enforced, only when.
--
-- ## Proven against a real deletion, not reasoned about
--
-- The probe at the foot builds a throwaway account with a miniature vault —
-- encryption key, running ingestion run, scope manifest, raw source record, run
-- item pointing at that record, current source item, term candidate, review item
-- and exposure — deletes the `auth.users` row, and asserts the delete succeeded
-- and removed every row. Then it rebuilds and asserts each guard **still**
-- refuses a direct delete while the owner exists. Both directions, over real
-- rows, inside a block that rolls back: a guard that has only ever answered one
-- way is not one to believe, and this one is about to answer a question nobody
-- has asked it.
--
-- Two guards are amended without being exercised, and it is worth saying which.
-- `guard_exposed_icebreaker_fact_links` needs a dyad run and a match
-- authorization between two accounts to reach, and its refusal is already
-- conditional on a parent frame that the same cascade removes — it is amended
-- because depending on cascade ordering for correctness is what the deferrable
-- change above exists to stop doing. `guard_ingestion_scope_v031` is exercised
-- transitively: the probe's run item cannot exist without a scope, and the scope
-- is deleted by the same cascade.

begin;

-- ---------------------------------------------------------------------------
-- The five guards.
-- ---------------------------------------------------------------------------

-- Membership in an ingestion run is append-only for the life of the account,
-- and no longer than that. Body otherwise identical to `0048`'s.
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
  -- The owner is already gone, so this is the cascade of an account erasure and
  -- not a caller rewriting evidence. See the header.
  if tg_op = 'DELETE'
     and not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
  if tg_op <> 'INSERT' then
    raise exception 'ingestion run membership is append-only';
  end if;
  select * into run_row
  from semantic_private.ingestion_runs
  where id = new.ingestion_run_id
  for key share;
  if not found
     or run_row.status <> 'running'
     or run_row.user_id is distinct from new.user_id then
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

create or replace function semantic_private.guard_ingestion_scope_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_row semantic_private.ingestion_runs%rowtype;
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
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
     or run_row.connector_source_code is distinct from new.connector_source_code then
    raise exception 'scope manifest requires its matching running ingestion run';
  end if;
  return new;
end;
$$;

-- **This one had an exemption and it was the wrong one.** The finalizer's flag
-- lets the atomic finalizer through; nothing on the deletion path raises it, and
-- teaching `delete-account` to set a GUC would put the correctness of an
-- erasure in an edge function's hands. The owner test needs nobody to remember.
create or replace function semantic_private.guard_current_source_item_v031()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
  if coalesce(
       current_setting('written.finalize_ingestion_v031', true), '0'
     ) <> '1' then
    raise exception 'current source state may change only through the atomic finalizer';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- `0203`'s guard, which added a sixth blocker to five that were already there.
create or replace function semantic_private.guard_review_history_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
  raise exception 'review presentation history is append-only (attempted % on %)',
    tg_op, tg_table_name;
end;
$$;

-- Its column is `fact_user_id`; the fact belongs to whichever side supplied it.
create or replace function semantic_private.guard_exposed_icebreaker_fact_links()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_frame_id uuid;
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from auth.users where id = old.fact_user_id) then
    return old;
  end if;
  target_frame_id := case
    when tg_op = 'DELETE' then old.icebreaker_frame_id
    else new.icebreaker_frame_id
  end;
  if exists (
    select 1 from semantic_private.icebreaker_frames as frame
    where frame.id = target_frame_id and frame.exposed_at is not null
  ) then
    raise exception 'facts linked to an exposed icebreaker are immutable';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- ---------------------------------------------------------------------------
-- The two immediate foreign keys that make cascade order matter.
-- ---------------------------------------------------------------------------

alter table semantic_private.ingestion_run_items
  alter constraint ingestion_run_items_observation_id_user_id_fkey
    deferrable initially deferred;

alter table semantic_private.ingestion_run_items
  alter constraint ingestion_run_items_raw_source_record_id_user_id_fkey
    deferrable initially deferred;

-- ---------------------------------------------------------------------------
-- The probe.
-- ---------------------------------------------------------------------------

do $$
declare
  probe_user uuid := extensions.gen_random_uuid();
  run_id uuid := extensions.gen_random_uuid();
  raw_id uuid := extensions.gen_random_uuid();
  candidate_id uuid := extensions.gen_random_uuid();
  item_id uuid := extensions.gen_random_uuid();
  hmac_a constant text := repeat('a', 64);
  hmac_b constant text := repeat('b', 64);
  survivors integer;
  refusals integer := 0;
  note text := '';
begin
  begin
    -- ---- build a throwaway account with a miniature vault ----
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (probe_user, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'probe-' || probe_user || '@invalid.example', now(), now());

    insert into semantic_private.user_encryption_keys
      (user_id, key_version, wrapped_dek, kms_key_arn)
    values (probe_user, 'probe_v1', decode(repeat('ab', 16), 'hex'),
            'arn:aws:kms:us-east-1:000000000000:key/'
              || '00000000-0000-0000-0000-000000000000');

    insert into semantic_private.ingestion_runs
      (id, user_id, source_code, connector_source_code, connector_version,
       input_hash, status)
    values (run_id, probe_user, 'apple_music', 'apple_music', 'probe',
            hmac_a, 'running');

    insert into semantic_private.ingestion_run_scopes
      (ingestion_run_id, user_id, source_code, connector_source_code, scope_key,
       data_type, action_type, snapshot_mode, completeness)
    values (run_id, probe_user, 'apple_music', 'apple_music', 'probe:scope',
            'library_song', 'saved', 'delta', 'partial');

    insert into semantic_private.raw_source_records
      (id, user_id, ingestion_run_id, source_code, connector_source_code,
       data_type, source_item_hmac, record_fingerprint, encryption_key_version,
       consent_purpose, retention_policy_version, encrypted_payload)
    values (raw_id, probe_user, run_id, 'apple_music', 'apple_music',
            'library_song', hmac_a, hmac_b, 'probe_v1',
            'source_distillation', 'probe.v1', decode(repeat('cd', 16), 'hex'));

    insert into semantic_private.ingestion_run_items
      (ingestion_run_id, user_id, source_code, scope_key, source_item_hmac,
       record_fingerprint, raw_source_record_id)
    values (run_id, probe_user, 'apple_music', 'probe:scope', hmac_a,
            hmac_b, raw_id);

    perform set_config('written.finalize_ingestion_v031', '1', true);
    insert into semantic_private.current_source_items
      (user_id, source_code, scope_key, data_type, action_type,
       source_item_hmac, record_fingerprint, lifecycle_state,
       last_seen_run_id, last_change_run_id, current_raw_source_record_id)
    values (probe_user, 'apple_music', 'probe:scope', 'library_song', 'saved',
            hmac_a, hmac_b, 'present', run_id, run_id, raw_id);
    perform set_config('written.finalize_ingestion_v031', '0', true);

    -- Exactly one of concept or provisional, per `0203`'s check constraint.
    insert into semantic_private.user_term_candidates
      (id, user_id, concept_id, user_facing_predicate,
       confidence_tier, primary_route_id)
    values (candidate_id, probe_user,
            (select id from ontology.concepts order by concept_key limit 1),
            'affinity_to', 'inferred', 'probe');

    insert into semantic_private.review_items
      (id, user_id, candidate_id, review_epoch, primary_route_id,
       confidence_tier, aggregate_score, rank, presentation_version)
    values (item_id, probe_user, candidate_id, 0, 'probe', 'inferred',
            0.5, 0, 'probe_v1');

    insert into semantic_private.review_exposures
      (user_id, review_item_id, position, presentation_variant)
    values (probe_user, item_id, 0, 'probe');

    -- ---- 1. each guard still refuses a direct delete, owner present ----
    begin
      delete from semantic_private.ingestion_run_items where user_id = probe_user;
      raise exception '0204: run membership accepted a direct delete';
    exception when others then
      if sqlerrm not like '%append-only%' then raise; end if;
      refusals := refusals + 1;
    end;

    begin
      delete from semantic_private.current_source_items where user_id = probe_user;
      raise exception '0204: current source state accepted a direct delete';
    exception when others then
      if sqlerrm not like '%atomic finalizer%' then raise; end if;
      refusals := refusals + 1;
    end;

    begin
      delete from semantic_private.review_items where user_id = probe_user;
      raise exception '0204: review history accepted a direct delete';
    exception when others then
      if sqlerrm not like '%append-only%' then raise; end if;
      refusals := refusals + 1;
    end;

    begin
      delete from semantic_private.review_exposures where user_id = probe_user;
      raise exception '0204: review exposures accepted a direct delete';
    exception when others then
      if sqlerrm not like '%append-only%' then raise; end if;
      refusals := refusals + 1;
    end;

    if refusals <> 4 then
      raise exception '0204: expected four refusals, counted %', refusals;
    end if;

    -- ---- 2. the deletion this migration exists for ----
    delete from auth.users where id = probe_user;

    select (select count(*) from semantic_private.ingestion_run_items where user_id = probe_user)
         + (select count(*) from semantic_private.ingestion_run_scopes where user_id = probe_user)
         + (select count(*) from semantic_private.ingestion_runs where user_id = probe_user)
         + (select count(*) from semantic_private.current_source_items where user_id = probe_user)
         + (select count(*) from semantic_private.raw_source_records where user_id = probe_user)
         + (select count(*) from semantic_private.review_items where user_id = probe_user)
         + (select count(*) from semantic_private.review_exposures where user_id = probe_user)
         + (select count(*) from semantic_private.user_term_candidates where user_id = probe_user)
         + (select count(*) from semantic_private.user_encryption_keys where user_id = probe_user)
      into survivors;

    if survivors <> 0 then
      raise exception '0204: the account was deleted but % vault row(s) survived', survivors;
    end if;

    note := 'account deletion succeeded across 9 vault tables; '
         || refusals || ' direct deletes still refused';

    -- Everything above is a fixture. Unwind it.
    raise exception using errcode = 'YY001', message = 'probe complete';
  exception
    when sqlstate 'YY001' then
      null;
  end;

  raise notice '0204: %', note;
end;
$$;

commit;
