-- 0362 — no Suggested lane, and the bootstrap sees David for the first time.
--
-- **The owner's direction, 2026-08-25: "there should be no suggested now,
-- since everything is presumed to be correct and only demoted when struck
-- off."** The calibration card's model — propose, review, keep-or-strike —
-- is superseded on the Memories surface by the cutoff bootstrap's model:
-- every term is shown as standing, and a strike is the only demotion. The
-- surface goes dark the way surfaces were built to: `calibration_reads`
-- off, which `assert_surface_allowed('calibration')` reads and the app
-- already renders as "no card". The lane's tables, history and machinery
-- are untouched — this is the rollback contract exercised, not a removal.
--
-- **And the test is structured as a first sight of David's data.** His 72
-- active term suppressions, 7 surface suppressions and 6 suppressed
-- preferences are judgments made against earlier frameworks' proposals;
-- counting them into the cutoff fit would price the old framework's errors
-- into the new framework's thresholds. They are deactivated — `active =
-- false` with the restore timestamp, `display_state = 'default'` — never
-- deleted: the append-only history of having struck them stands, exactly as
-- the restore path always leaves it.
--
-- Replayable by asserting the transformation: on a clean database the flag
-- row exists (0048 seeds it) and flips; the per-user updates touch zero
-- rows and that is the correct answer there.

begin;

update semantic_private.feature_flags
   set enabled = false
 where flag_key = 'calibration_reads';

update semantic_private.user_term_suppressions
   set active = false, restored_at = now()
 where user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'
   and active;

update semantic_private.user_suppressions
   set active = false, lifted_at = now()
 where user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'
   and active;

update semantic_private.assertion_preferences
   set display_state = 'default'
 where user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'
   and display_state = 'suppressed';

do $$
declare
  still_on boolean;
  remaining integer;
begin
  select enabled into still_on
    from semantic_private.feature_flags where flag_key = 'calibration_reads';
  if coalesce(still_on, false) then
    raise exception '0362: calibration_reads is still enabled';
  end if;

  select count(*) into remaining
    from semantic_private.user_term_suppressions
   where user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1' and active;
  if remaining > 0 then
    raise exception '0362: % term suppression(s) still active', remaining;
  end if;

  raise notice '0362: suggested is dark; the slate is clean';
end;
$$;

commit;
