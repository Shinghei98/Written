-- 0240 — the database picks the release, the evidence belongs to the
-- observation, and the model role is alone.
--
-- Stage 3.0 continued. `qwen_overlay` stays `off`.
--
-- `0239` moved the forgery rather than removing it, and two of its constraints
-- proved less than their comments claimed. Three findings, all correct:
--
-- ## 1. Any slot authorized any manifest
--
-- The trigger read `where m.id = new.release_manifest_id` — so the **caller
-- still chose the manifest**, and any of the three deployment slots pointing at
-- it made that choice authoritative. A process running the evaluation lane
-- could pass the shadow release's id and be handed `shadow`. The lane stopped
-- being caller-supplied and the *release* took its place, which is the same hole
-- one indirection along.
--
-- A model call is authorized by **the deployment, not by the caller's argument.**
-- At most one slot may be bound to a manifest whose lane is not `off`; that is
-- the release in force, and `authorized_model_release()` is the only thing that
-- names it. The trigger now discards `release_manifest_id` exactly as it already
-- discarded `model_lane_mode`, and a caller who passes the wrong one is not
-- refused — they are ignored, which is the same answer for a mistake and an
-- attempt.
--
-- ## 2. Two foreign keys did not prove one relationship
--
-- `(observation_id, user_id)` and `(source_text_evidence_id, user_id)` each held
-- their own end and neither tied them together: the evidence could belong to a
-- **different observation of the same account**, which is exactly the case the
-- staleness check exists to catch and exactly the case it would miss. The
-- relationship is the triple, so the constraint is the triple —
-- `source_text_evidence` gains `unique (id, observation_id, user_id)` to be
-- referenced on those terms.
--
-- And the lineage is now required of **every user-scoped item, including
-- failures.** `0239` required evidence only on success, which is backwards: a
-- `timeout` on somebody's title is still a row about their data, and an erasure
-- that walks evidence would not find it. Three fields, all present or all
-- absent — a fixture is the only shape with none.
--
-- Currency is still asked only of a success, because `source_stale` is the
-- outcome for a call that read something no longer current. Requiring live
-- evidence on a failure would make that outcome unrecordable.
--
-- ## 3. `bypassrls` was granted and never bounded
--
-- `semantic_model_worker` carries `bypassrls`, so what it *is* matters as much
-- as what it is granted, and `0239` asserted only grants. A role that can be
-- reached by `set role` from the deterministic worker is not a second identity;
-- it is the first one with another name.
--
-- The assertions live in `supabase/tests/0239_model_lane_authority_contract.sql`
-- rather than here, in one place with the grant checks they belong beside:
-- membership in both directions and transitively, and the attributes pinned —
-- no login, no inheritance, no superuser, no createrole, no createdb, and
-- `bypassrls` still present, because losing it would move every refusal from
-- the grant list to RLS and make the rest of that file pass for the wrong
-- reason.

-- ---------------------------------------------------------------------------
-- 1. One release is in force, and the database names it.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.authorized_model_release()
returns table (release_manifest_id uuid, model_lane_mode text)
language sql
stable
set search_path = ''
as $$
  select m.id, m.model_lane_mode
    from ontology.deployment_slots s
    join ontology.release_manifests m on m.id = s.release_manifest_id
   where m.model_lane_mode <> 'off'
$$;

comment on function semantic_private.authorized_model_release() is
  'The single release a model call may run under. Returns no row when nothing '
  'is deployed for a calling lane, and more than one only if the slot guard has '
  'been bypassed — both of which the invocation trigger refuses.';

create or replace function semantic_private.guard_one_calling_deployment()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  others integer;
begin
  select count(*) into others
    from ontology.deployment_slots s
    join ontology.release_manifests m on m.id = s.release_manifest_id
   where m.model_lane_mode <> 'off'
     and s.slot <> new.slot;
  if others > 0 then
    raise exception
      'a calling-lane release is already deployed; there is one model release in force, not three slots to choose from';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_one_calling_deployment on ontology.deployment_slots;
create trigger guard_one_calling_deployment
  before insert or update on ontology.deployment_slots
  for each row execute function semantic_private.guard_one_calling_deployment();

create or replace function semantic_private.derive_invocation_lane()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  authorized record;
  found integer;
begin
  if tg_op = 'UPDATE' then
    if new.release_manifest_id is distinct from old.release_manifest_id
       or new.model_lane_mode is distinct from old.model_lane_mode then
      raise exception 'an invocation may not change the release or lane it ran in';
    end if;
    return new;
  end if;

  select count(*) into found from semantic_private.authorized_model_release();
  if found = 0 then
    raise exception 'no release is deployed for a calling lane, so nothing authorizes a model call';
  end if;
  if found > 1 then
    raise exception 'more than one calling-lane release is deployed; the release in force is ambiguous';
  end if;
  select * into authorized from semantic_private.authorized_model_release();

  -- **The caller's arguments are discarded, both of them.** `0239` stopped an
  -- invocation stating its lane and left it choosing its release, which chose
  -- the lane. A mistake and an attempt get the same answer: the deployment.
  new.release_manifest_id := authorized.release_manifest_id;
  new.model_lane_mode := authorized.model_lane_mode;

  if new.model_lane_mode = 'evaluation' and new.user_id is not null then
    raise exception 'an evaluation invocation cannot name a user';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The evidence belongs to the item's observation.
-- ---------------------------------------------------------------------------

alter table semantic_private.source_text_evidence
  drop constraint if exists source_text_evidence_observation_identity_key;
alter table semantic_private.source_text_evidence
  add constraint source_text_evidence_observation_identity_key
  unique (id, observation_id, user_id);

alter table semantic_private.model_invocation_items
  drop constraint if exists model_invocation_items_evidence_fk;
alter table semantic_private.model_invocation_items
  add constraint model_invocation_items_evidence_fk
  foreign key (source_text_evidence_id, observation_id, user_id)
  references semantic_private.source_text_evidence (id, observation_id, user_id)
  on delete no action;

alter table semantic_private.model_invocation_items
  drop constraint if exists model_invocation_items_user_scope_check;
alter table semantic_private.model_invocation_items
  drop constraint if exists model_invocation_items_lineage_triple_check;
alter table semantic_private.model_invocation_items
  add constraint model_invocation_items_lineage_triple_check
  check (num_nonnulls(user_id, observation_id, source_text_evidence_id) in (0, 3));

comment on constraint model_invocation_items_lineage_triple_check
  on semantic_private.model_invocation_items is
  'All three or none. A failure on somebody''s title is still a row about their '
  'data, and an erasure that walks evidence has to be able to find it; a fixture '
  'is the only shape with none.';

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
    if new.user_id is not null
       or new.observation_id is not null
       or new.source_text_evidence_id is not null then
      raise exception
        'an evaluation item is fixture-only: no user, observation or retained source text';
    end if;
    return new;
  end if;

  -- Currency is asked of a success only. `source_stale` is the outcome for a
  -- call that read something no longer current, and requiring live evidence on
  -- a failure would make that outcome unrecordable.
  if new.user_id is not null and new.outcome = 'succeeded' then
    if not exists (
      select 1 from semantic_private.source_text_evidence e
       where e.id = new.source_text_evidence_id
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

-- ---------------------------------------------------------------------------
-- 4. What must stay true.
-- ---------------------------------------------------------------------------

do $$
begin
  -- The triple, refused as a pair. Stated as a transformation so it answers on
  -- an empty database.
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, user_id, observation_id,
       logical_extraction_key, outcome)
    values (extensions.gen_random_uuid(), 0, extensions.gen_random_uuid(),
            extensions.gen_random_uuid(), 'probe', 'timeout');
    raise exception '0240: an item carried two thirds of its lineage';
  exception
    when check_violation then null;
    when foreign_key_violation then null;
  end;
end;
$$;
