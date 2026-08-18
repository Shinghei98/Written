-- 0239 — an invocation cannot name its own lane, and the lane that calls a model
-- cannot write semantics.
--
-- Stage 3.0, a security preflight. `qwen_overlay` stays `off` and nothing here
-- permits a model call.
--
-- ## What `0237` actually proved, and what it did not
--
-- `0237` said a mode boundary the worker cannot talk its way past. That was too
-- strong, and the review that found it was right on four counts:
--
-- 1. **An invocation could self-identify.** `release_manifest_id` and
--    `model_lane_mode` were both nullable and both caller-supplied, and the
--    mention guard read the lane off the invocation row. A worker inserting
--    `model_lane_mode = 'shadow'` with no manifest at all was writing its own
--    permission and then being checked against it.
-- 2. **`semantic_worker` writes provisionals, candidates and assertions
--    directly.** `0203` grants insert on every overlay table and `0079` grants
--    insert and update on `user_assertions`. The mention guard governs what may
--    *descend* from a model call; it has nothing to say to a role that can
--    write the descendant without the ancestor.
-- 3. **An item's `observation_id` and `source_text_evidence_id` were bare
--    uuids.** No foreign key, so they could name another account's rows — and
--    leaving the evidence null skipped the deletion check entirely, which is
--    the one refusal that was supposed to stop a call committing against text
--    somebody had erased.
-- 4. **`0237`'s own contract blessed the hole.** Its `shadow_call` names no
--    manifest, and property 7 asserts that call may create a user mention. Green
--    CI was verifying the incomplete model rather than disproving the bypass.
--
-- All four are true. This closes the first, third and fourth, and answers the
-- second with a role rather than a revocation.
--
-- ## The lane is derived, never supplied
--
-- `release_manifest_id` becomes `not null`, and the manifest must be one a
-- **deployment slot points at** — a manifest nobody deployed is a row somebody
-- wrote, not an authority. `model_lane_mode` is then overwritten from that
-- manifest on insert, whatever the caller passed, and refused on update. It is
-- stored rather than joined because a manifest's lane may move and an invocation
-- must keep saying what it was permitted to do *at the time*; it is a snapshot,
-- and a snapshot the caller cannot forge.
--
-- ## Evaluation is fixture-only, structurally
--
-- The memo defines `evaluation` as model calls with operational metadata and no
-- user semantics. That was a sentence about intent; it is a constraint now. An
-- evaluation invocation carries no `user_id`, and its items carry no user, no
-- observation and no source-text evidence. There is nothing for it to be about.
--
-- ## A user-backed success must name live evidence
--
-- The gap the review found: the staleness check only fired when
-- `source_text_evidence_id` was set, so omitting it skipped the check. A
-- user-scoped `succeeded` item must now name evidence, and that evidence must be
-- `current`, unexpired and still holding its text — which `0238` made a state
-- that can actually be false.
--
-- ## Two identities, and neither may become the other
--
-- Revoking `semantic_worker`'s writes wholesale would break the deterministic
-- lane, which legitimately writes provisionals and candidates with no model
-- involved. The honest separation is the one this schema already uses for
-- ingestion: **a different role.**
--
-- `semantic_model_worker` may record invocations and items and **nothing else**.
-- It holds no grant on mentions, resolutions, provisionals, candidates, support
-- links, review rows or assertions — so a process running the model lane cannot
-- write user semantics through any table, guarded or not. `semantic_worker`
-- loses its insert on `model_invocations` in the same breath: the deterministic
-- lane has no business recording a model call, and leaving it would make the
-- separation a convention.
--
-- When the gateway ships, the model role gets one narrowly guarded
-- `security definer` function to write a validated mention. It does not get one
-- today, because there is no gateway and a capability granted before its caller
-- exists is a capability nobody is watching.

-- ---------------------------------------------------------------------------
-- 1. Every invocation names a deployed release.
-- ---------------------------------------------------------------------------

update semantic_private.model_invocations
   set release_manifest_id = null
 where release_manifest_id is not null
   and not exists (select 1 from ontology.deployment_slots s
                    where s.release_manifest_id = model_invocations.release_manifest_id);

-- The table is empty; this is a decision rather than a backfill.
delete from semantic_private.model_invocations where release_manifest_id is null;

alter table semantic_private.model_invocations
  alter column release_manifest_id set not null,
  alter column model_lane_mode set not null;

create or replace function semantic_private.derive_invocation_lane()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  authorized_lane text;
begin
  if tg_op = 'UPDATE' then
    if new.release_manifest_id is distinct from old.release_manifest_id
       or new.model_lane_mode is distinct from old.model_lane_mode then
      raise exception 'an invocation may not change the release or lane it ran in';
    end if;
    return new;
  end if;

  -- **A manifest nobody deployed is not an authority.** `deployment_slots` is
  -- what makes a manifest the one in force, and it is the only reason a release
  -- row means anything beyond that somebody inserted it.
  select m.model_lane_mode into authorized_lane
    from ontology.release_manifests m
    join ontology.deployment_slots s on s.release_manifest_id = m.id
   where m.id = new.release_manifest_id
   limit 1;

  if authorized_lane is null then
    raise exception
      'release manifest % is not bound to a deployment slot, so it authorizes nothing',
      new.release_manifest_id;
  end if;

  -- Whatever the caller passed is discarded. The lane is a property of the
  -- deployment, and an invocation that could state its own would be writing its
  -- own permission and then being checked against it.
  new.model_lane_mode := authorized_lane;

  -- An evaluation call is about fixtures. There is no person it may name.
  if authorized_lane = 'evaluation' and new.user_id is not null then
    raise exception 'an evaluation invocation cannot name a user';
  end if;

  return new;
end;
$$;

drop trigger if exists derive_invocation_lane on semantic_private.model_invocations;
create trigger derive_invocation_lane
  before insert or update on semantic_private.model_invocations
  for each row execute function semantic_private.derive_invocation_lane();

-- ---------------------------------------------------------------------------
-- 2. An item cannot point outside its own account.
-- ---------------------------------------------------------------------------

alter table semantic_private.model_invocation_items
  drop constraint if exists model_invocation_items_observation_fk;
alter table semantic_private.model_invocation_items
  add constraint model_invocation_items_observation_fk
  foreign key (observation_id, user_id)
  references semantic_private.observations (id, user_id) on delete no action;

alter table semantic_private.model_invocation_items
  drop constraint if exists model_invocation_items_evidence_fk;
alter table semantic_private.model_invocation_items
  add constraint model_invocation_items_evidence_fk
  foreign key (source_text_evidence_id, user_id)
  references semantic_private.source_text_evidence (id, user_id) on delete no action;

create or replace function semantic_private.guard_invocation_item_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  lane text;
begin
  select v.model_lane_mode into lane
    from semantic_private.model_invocations v
   where v.id = new.invocation_id;

  if lane = 'evaluation' then
    -- Fixture-only, and stated as three separate refusals so the message says
    -- which one was attempted.
    if new.user_id is not null then
      raise exception 'an evaluation item cannot name a user';
    end if;
    if new.observation_id is not null then
      raise exception 'an evaluation item cannot name an observation';
    end if;
    if new.source_text_evidence_id is not null then
      raise exception 'an evaluation item cannot name retained source text';
    end if;
    return new;
  end if;

  -- **A user-backed success must name evidence that is still there.** The gap
  -- `0237` left: its staleness check only fired when the evidence was named, so
  -- omitting it skipped the check that stops a call committing against text
  -- somebody has erased.
  if new.user_id is not null and new.outcome = 'succeeded' then
    if new.source_text_evidence_id is null then
      raise exception
        'a user-backed successful item must name the source text it read';
    end if;
    if not exists (
      select 1 from semantic_private.source_text_evidence e
       where e.id = new.source_text_evidence_id
         and e.user_id = new.user_id
         and e.refresh_status = 'current'
         and e.expires_at > now()
         and e.encrypted_text is not null
    ) then
      raise exception
        'the source text behind this item is expired, redacted or not current';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_invocation_item_scope
  on semantic_private.model_invocation_items;
create trigger guard_invocation_item_scope
  before insert on semantic_private.model_invocation_items
  for each row execute function semantic_private.guard_invocation_item_scope();

-- ---------------------------------------------------------------------------
-- 3. The lane that calls a model cannot write semantics.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'semantic_model_worker') then
    -- **`bypassrls`, like `semantic_worker`, and that is not a grant.**
    -- `semantic_private` has row-level security on and no policies anywhere, so
    -- a role without it cannot reach these tables at all — and a refusal that
    -- comes from RLS rather than from the grant list would make the assertions
    -- below pass for the wrong reason, which is the failure mode this whole
    -- migration exists to remove.
    create role semantic_model_worker nologin noinherit bypassrls;
  end if;
end;
$$;

revoke all on all tables in schema semantic_private from semantic_model_worker;
revoke all on all tables in schema ontology from semantic_model_worker;
revoke all on all tables in schema public from semantic_model_worker;

grant usage on schema semantic_private to semantic_model_worker;
grant usage on schema ontology to semantic_model_worker;
grant select, insert on semantic_private.model_invocations to semantic_model_worker;
grant select, insert on semantic_private.model_invocation_items to semantic_model_worker;
-- It must be able to read what authorizes it, and nothing else.
grant select on ontology.release_manifests to semantic_model_worker;
grant select on ontology.deployment_slots to semantic_model_worker;
grant select on semantic_private.source_text_evidence to semantic_model_worker;

-- **The deterministic lane has no business recording a model call.** Leaving
-- this grant would make the separation a convention rather than a boundary.
revoke insert on semantic_private.model_invocations from semantic_worker;

-- ---------------------------------------------------------------------------
-- 4. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  target text;
  forbidden constant text[] := array[
    'observation_mentions', 'mention_resolutions', 'provisional_entities',
    'user_term_candidates', 'candidate_support_links', 'review_items',
    'review_events', 'review_exposures', 'user_term_suppressions',
    'user_suppressions', 'user_assertions', 'observations',
    'raw_source_records'
  ];
begin
  -- The whole of the third answer: a role, not a rule. If the model lane can
  -- reach any of these directly, the mention guard is decoration.
  foreach target in array forbidden loop
    if has_table_privilege('semantic_model_worker',
                           format('semantic_private.%I', target), 'INSERT')
       or has_table_privilege('semantic_model_worker',
                              format('semantic_private.%I', target), 'UPDATE') then
      raise exception
        '0239: semantic_model_worker can write semantic_private.%', target;
    end if;
  end loop;

  if has_table_privilege('semantic_worker',
                         'semantic_private.model_invocations', 'INSERT') then
    raise exception '0239: the deterministic lane can still record a model call';
  end if;

  if not has_table_privilege('semantic_model_worker',
                             'semantic_private.model_invocation_items', 'INSERT') then
    raise exception '0239: the model lane cannot record its own items';
  end if;
end;
$$;
