-- 0316 — the calibration surface is switched on.
--
-- **`calibration_reads` has been false since it was seeded**, in `0227`, and
-- `0227:430` and `0228:197` each assert it is still false. Those assertions
-- are true statements about their own moment and stay true in replay order;
-- this migration is the moment it changes.
--
-- **What it turns on, precisely.** `api.begin_calibration` calls
-- `assert_surface_allowed('calibration')`, which maps to this flag and to no
-- other — deliberately not shared with `memories_reads`, because a candidate
-- the system has not concluded is a different exposure from an assertion, and
-- a shared flag could not be pulled without taking Memories down with it.
-- With it off, the client reads the `42501` as "switched off" and renders no
-- card at all, silently: `SemanticSurfaceService` returns `[]` rather than an
-- error. So a person with a full review page and this flag down sees exactly
-- what a person with nothing sees, which is why this is the first thing to
-- check when the surface looks empty.
--
-- **It grants no new data.** Everything `begin_calibration` returns is the
-- caller's own — `auth.uid()` is read from the session and there is no
-- parameter for whose — and the rows it reads were built for that person by
-- the overlay. The kill switch still overrides it, which the check below
-- proves rather than assumes.

update semantic_private.feature_flags
   set enabled = true, updated_at = now()
 where flag_key = 'calibration_reads';

do $$
declare
  refused boolean;
  memories_before boolean;
begin
  -- **Captured, not asserted.** `memories_reads` is true in production because
  -- somebody flipped it by hand; no migration does, so a replay against a
  -- clean database finds it false. Asserting its *value* would be asserting a
  -- precondition only one database satisfies — the thing that makes a
  -- migration unreplayable. What this migration owes is that it did not move
  -- it, which is a statement about the transformation and answers the same on
  -- both databases.
  select enabled into memories_before from semantic_private.feature_flags
   where flag_key = 'memories_reads';

  if not exists (select 1 from semantic_private.feature_flags
                  where flag_key = 'calibration_reads' and enabled) then
    raise exception '0316: the flag did not move';
  end if;

  -- **The predicate is exercised both ways, not read.** A check on a flag's
  -- value is not a check on the guard's behaviour, and this project's rule is
  -- that a predicate is not believed until it has answered both ways over
  -- real data. `assert_surface_allowed` is `stable`, never `immutable`,
  -- precisely so it is not folded at plan time and this still means something.
  --
  -- `auth.uid()` is null in a migration, so `flag_enabled_v031` is asked
  -- directly here; `begin_calibration`'s own call is exercised by the app.
  if not semantic_private.flag_enabled_v031('calibration_reads', null) then
    raise exception '0316: the flag reads as enabled and the guard disagrees';
  end if;

  -- The kill switch still wins. Raised, checked, and put back inside the same
  -- transaction, so a failure between the two cannot leave it up.
  update semantic_private.feature_flags
     set enabled = true where flag_key = 'emergency_privacy_kill_switch';
  refused := not semantic_private.flag_enabled_v031('calibration_reads', null);
  update semantic_private.feature_flags
     set enabled = false where flag_key = 'emergency_privacy_kill_switch';
  if not refused then
    raise exception
      '0316: the kill switch no longer overrides the calibration surface';
  end if;
  if semantic_private.flag_enabled_v031('emergency_privacy_kill_switch', null) then
    raise exception '0316: the kill switch was left raised';
  end if;

  -- Memories is untouched: the two flags are separate on purpose, and whatever
  -- `memories_reads` was before this ran, it is that now.
  if (select enabled from semantic_private.feature_flags
       where flag_key = 'memories_reads') is distinct from memories_before then
    raise exception '0316: memories_reads changed, and it should not have';
  end if;

  raise notice '0316: calibration answers; the kill switch still overrides it';
end;
$$;
