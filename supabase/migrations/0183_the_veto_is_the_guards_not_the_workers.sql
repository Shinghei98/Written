-- 0183 — the veto is the guard's, not the worker's.
--
-- ## What 0182 left one step short
--
-- `0182` made `guard_youtube_assertion_evidence` shut the offending permission
-- instead of aborting the run. The next attempt answered:
--
--     42501  permission denied for table assertion_surface_permissions
--
-- A trigger function runs as whoever fired it, and that is `semantic_worker`,
-- which holds `select` and `insert` on that table and deliberately **no
-- `update`**. So the guard could see the permission it had to shut and could not
-- shut it.
--
-- ## Why the grant is the wrong repair
--
-- Granting `update` would let the thing reachable from a queue rewrite surface
-- permissions — including opening them. The other guards would refuse the
-- obvious abuses (`assertion_permissions_guard_youtube` raises on an unapproved
-- `can_select`), but that is a second line of defence standing in for a
-- privilege that was never needed: the worker has no business editing what a
-- term is allowed to do, and `semantic_worker`'s grant list is enumerated table
-- by table precisely so a widening is a decision rather than a side effect.
--
-- **So the function becomes `security definer`.** The veto is then performed by
-- the guard under its owner's rights, which is what a guard is, and the caller's
-- privileges are unchanged — asserted below rather than assumed, in both
-- directions: the worker still cannot update the table, and the guard still can.
--
-- `set search_path to ''` was already on this function and matters more now:
-- every object it names is schema-qualified, which is what makes a definer
-- function safe to leave reachable.

begin;

create or replace function semantic_private.guard_youtube_assertion_evidence()
returns trigger
language plpgsql
security definer
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
  is_definer boolean;
  owner_name text;
begin
  select p.prosecdef, pg_get_userbyid(p.proowner)
    into is_definer, owner_name
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'guard_youtube_assertion_evidence';
  if not is_definer then
    raise exception '0183: the guard is not security definer and cannot shut a permission';
  end if;

  -- **The privilege the worker must still not have.** This is the whole point of
  -- the migration: the veto moved to the guard so that this stays false.
  if has_table_privilege('semantic_worker',
                         'semantic_private.assertion_surface_permissions',
                         'update') then
    raise exception '0183: semantic_worker gained update on assertion_surface_permissions';
  end if;

  -- And the owner, which is what the definer rights are.
  if not has_table_privilege(owner_name,
                             'semantic_private.assertion_surface_permissions',
                             'update') then
    raise exception '0183: the guard owner % cannot update the table it must shut', owner_name;
  end if;
end;
$$;

commit;
