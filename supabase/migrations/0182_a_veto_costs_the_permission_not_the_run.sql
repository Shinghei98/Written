-- 0182 — a veto costs the permission, not the run.
--
-- ## What happened
--
-- `Hearthstone` reached the vault for the first time on 2026-08-15, in the
-- keywords of a subscribed channel (`0168`'s whole purpose). The scorer then
-- failed, and kept failing:
--
--     P0001  YouTube assertion evidence conflicts with surface policy
--
-- `guard_youtube_assertion_evidence` refuses to attach YouTube evidence to an
-- assertion holding `can_select` on `matching`, `bio` or `icebreaker` while
-- `allow_cross_source_fusion`, `allow_bio` and `allow_icebreaker` are false.
-- That refusal is correct. **What was wrong is what it cost**: a `raise` in a
-- `before insert` trigger aborts the statement, the transaction and the whole
-- run, so one policy-refused term froze every assertion the account had. Its
-- Memories page stopped moving at 12:27 and would not have moved again.
--
-- ## Why it had never fired before
--
-- Permissions are opened by `initialize_assertion_surface_permissions`, which
-- runs on the `user_assertions` insert — *before any evidence row exists*. So
-- nothing can veto at the moment of opening. Every YouTube-evidenced concept so
-- far also had a non-YouTube witness whose evidence landed first and shut the
-- permission, so the guard never met an open one.
--
-- **`work:hearthstone` is the first assertion this system has ever had whose
-- only witness is YouTube.** It is therefore the first to reach this trigger
-- with `matching` and `bio` still open, and the first to pay the full price of
-- the raise.
--
-- ## The change, which is `0128`'s own principle one table further along
--
-- `0128` met exactly this conflict when *opening* the permissions and resolved
-- it in words worth repeating: *"the row is still born closed and opened
-- immediately afterwards, inside a block that tolerates a refusal. The guards
-- keep their veto; what changes is that a veto costs the permission rather than
-- the assertion."* It wrapped the opening in an exception block and stopped
-- there, because the opening was the only place the conflict could arise —
-- until an assertion existed that YouTube alone attests.
--
-- So this guard now **shuts the permission instead of raising**. The invariant
-- is unchanged and is enforced more completely than before: YouTube evidence
-- still can never back a `matching`, `bio` or `icebreaker` selection, and now it
-- cannot do so *even in the ordering where the permission was opened first* —
-- which previously did not fail closed, it failed loudly and left the state
-- unwritten.
--
-- **Memories is untouched**, being outside the surfaces this guard names. That
-- is the whole product outcome: the term appears where its owner can read and
-- strike it off, and reaches nobody else.
--
-- ## Two details the schema decided rather than this migration
--
-- **`permission_source = 'policy_guard'`** already exists in that column's check
-- constraint, alongside `default_policy` and `user_choice`. A guard writing a
-- permission was anticipated; this is the first thing to use it, and it is what
-- distinguishes a permission somebody never had from one a policy took away.
--
-- **All three flags go down together**, because
-- `assertion_surface_permissions_lattice_check` reads `can_name` implies
-- `can_select` and `can_explain` implies `can_name`. Shutting selection while
-- leaving naming open would not be a laxer choice, it would be a constraint
-- violation — the lattice is what stops "may not be used but may be named".

begin;

create or replace function semantic_private.guard_youtube_assertion_evidence()
returns trigger
language plpgsql
set search_path to ''
as $function$
declare
  assertion_id_value uuid;
  source_code_value text;
  mapping_run_id uuid;
  mapping_fusion_allowed boolean;
  permission record;
  gate_name text;
begin
  select score.assertion_id, observation.source_code,
         mapping.semantic_run_id, mapping.cross_source_fusion_allowed
  into assertion_id_value, source_code_value,
       mapping_run_id, mapping_fusion_allowed
  from semantic_private.assertion_score_versions as score
  join semantic_private.observation_mappings as mapping
    on mapping.id = new.observation_mapping_id
   and mapping.user_id = new.user_id
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  where score.id = new.assertion_score_version_id
    and score.user_id = new.user_id;
  if source_code_value <> 'youtube' then return new; end if;
  for permission in
    select surface, can_select, can_explain
    from semantic_private.assertion_surface_permissions
    where assertion_id = assertion_id_value
      and user_id = new.user_id
      and surface in ('matching', 'bio', 'icebreaker')
      and (can_select or can_explain)
  loop
    gate_name := case permission.surface
      when 'matching' then 'cross_source_fusion'
      when 'bio' then 'bio'
      when 'icebreaker' then 'icebreaker'
    end;
    if permission.can_select and (
      not mapping_fusion_allowed
      or not semantic_private.youtube_run_gate_allowed(mapping_run_id, gate_name)
    ) then
      -- The veto, paid by the permission. All three together, or the lattice
      -- check refuses the write and we are back to a raise by another name.
      update semantic_private.assertion_surface_permissions
         set can_select = false,
             can_name = false,
             can_explain = false,
             permission_source = 'policy_guard'
       where assertion_id = assertion_id_value
         and user_id = new.user_id
         and surface = permission.surface;
    end if;
    if permission.can_explain and not semantic_private.youtube_run_gate_allowed(
      mapping_run_id, 'explanation'
    ) then
      update semantic_private.assertion_surface_permissions
         set can_explain = false,
             permission_source = 'policy_guard'
       where assertion_id = assertion_id_value
         and user_id = new.user_id
         and surface = permission.surface;
    end if;
  end loop;
  return new;
end;
$function$;

do $$
declare
  still_raises boolean;
begin
  -- **Not a proof of behaviour, and not pretending to be one.** The predicate is
  -- proven outside this transaction by running the recompute that was failing
  -- and reading the permissions it leaves behind: `memories` open, `matching`
  -- and `bio` shut with `permission_source = 'policy_guard'`. What is checked
  -- here is only that the function no longer carries the statement that cost the
  -- run, because that one *is* visible from the catalog.
  select prosrc ilike '%conflicts with surface policy%' into still_raises
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'guard_youtube_assertion_evidence';
  if still_raises then
    raise exception '0182: the guard still raises rather than shutting the permission';
  end if;

  -- The trigger must still exist and still be `before`: an `after` trigger would
  -- shut the permission only once the evidence row was already written, which is
  -- the same state by a longer route but stops being true if the write is ever
  -- rolled back independently.
  if not exists (
    select 1 from pg_trigger t
     where t.tgname = 'assertion_evidence_guard_youtube_permissions'
       and not t.tgisinternal
       and (t.tgtype & 2) <> 0
  ) then
    raise exception '0182: the before-insert trigger is missing';
  end if;
end;
$$;

commit;
