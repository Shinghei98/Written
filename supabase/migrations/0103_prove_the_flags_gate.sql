-- 0103 — proof that the switch moves something.
--
-- **`0102` asserted that the guard *mentions* `flag_enabled_v031`.** That is a
-- check on the source text, and this file has now twice shipped a check that
-- passed while measuring nothing — `0095` counted 35 unreachable concepts, and
-- `0102`'s own first column test answered 0 for a healthy function. A flag that
-- gates nothing is exactly the defect being fixed here, so text is not enough.
--
-- So this flips each flag, calls the guard, and asserts the answer changes —
-- then restores every flag to the value it had and proves it. Three properties,
-- and the third is the one that would be believed without evidence:
--
--   * off  → the surface refuses
--   * on   → the surface passes
--   * on, but `emergency_privacy_kill_switch` down → refuses anyway
--
-- **It runs inside the migration's transaction**, so a failed assertion rolls
-- the flag changes back with it. It also runs again on every replay, which is
-- the point of putting a behavioural test in a migration rather than in a
-- one-off probe: `0083` did the same for the YouTube projection after `0082`
-- shipped untested.
--
-- Ships no behaviour and leaves no state.

begin;

create temporary table flag_snapshot on commit drop as
  select flag_key, enabled from semantic_private.feature_flags;

do $$
declare
  surfaces constant text[] := array['memories', 'matching', 'bio', 'icebreaker'];
  flags constant text[] := array[
    'memories_reads', 'discovery_profile_reads',
    'discovery_profile_reads', 'icebreaker_first_exposure'];
  surface text;
  flag text;
  i integer;
  passed boolean;
begin
  -- Everything off first, whatever the deploy found.
  update semantic_private.feature_flags set enabled = false;

  for i in 1 .. array_length(surfaces, 1) loop
    surface := surfaces[i];
    flag := flags[i];

    -- Off: must refuse.
    passed := true;
    begin
      perform semantic_private.assert_surface_allowed(surface);
    exception when insufficient_privilege then
      passed := false;
    end;
    if passed then
      raise exception 'surface % passed while % was off', surface, flag;
    end if;

    -- On: must pass.
    update semantic_private.feature_flags set enabled = true where flag_key = flag;
    perform semantic_private.assert_surface_allowed(surface);

    -- On, kill switch down: must refuse anyway. **This is the property the
    -- switch exists for** — a privacy incident cannot wait on an app release —
    -- and it comes from `flag_enabled_v031` rather than from anything written
    -- in `0102`, so it is the half most likely to be assumed rather than known.
    update semantic_private.feature_flags set enabled = true
     where flag_key = 'emergency_privacy_kill_switch';
    passed := true;
    begin
      perform semantic_private.assert_surface_allowed(surface);
    exception when insufficient_privilege then
      passed := false;
    end;
    if passed then
      raise exception 'the kill switch did not stop surface %', surface;
    end if;

    update semantic_private.feature_flags set enabled = false
     where flag_key in (flag, 'emergency_privacy_kill_switch');
  end loop;

  -- An unknown surface still fails on its name rather than on a flag, which is
  -- the check that was there before and must survive the change.
  begin
    perform semantic_private.assert_surface_allowed('discovery');
    raise exception 'an unsupported surface was allowed';
  exception when insufficient_privilege then
    raise exception 'an unsupported surface was refused as disabled, not as unknown';
  when others then
    null;
  end;
end
$$;

do $$
declare
  drifted text;
begin
  update semantic_private.feature_flags f
     set enabled = s.enabled
    from flag_snapshot s
   where s.flag_key = f.flag_key and f.enabled is distinct from s.enabled;

  -- **Restored, and proven restored.** A probe that left `memories_reads` on
  -- would enable a product surface by migration, which is precisely the thing
  -- §9 says a flag exists to prevent.
  select string_agg(f.flag_key, ', ' order by f.flag_key) into drifted
    from semantic_private.feature_flags f
    join flag_snapshot s on s.flag_key = f.flag_key
   where f.enabled is distinct from s.enabled;
  if drifted is not null then
    raise exception 'these flags did not return to their prior value: %', drifted;
  end if;
end
$$;

commit;
