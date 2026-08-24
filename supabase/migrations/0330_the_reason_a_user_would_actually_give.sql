-- 0330 — `wrong_parent` becomes a reason a strike may carry.
--
-- **It could be priced and could never be recorded.** Three artifacts already
-- agree that `wrong_parent` is a reason:
--
--   * `api.strike_calibration_item` accepts it — `0294:74-79` puts it in the
--     nine-reason allowlist, so a tap carrying it passes the RPC's `case` and
--     reaches the insert unchanged rather than falling back.
--   * `0292` prices it twice: `classification_parent` at −2.00 and
--     `classification_root` at −0.10.
--   * `0292:11-17` maps the Cardinal spec's seven reason codes onto this
--     vocabulary, and `wrong_parent` is the one code that maps to itself.
--
-- The fourth refuses it. `review_events.reason`'s check has held fourteen
-- values since `0203:338-342` and `wrong_parent` is not among them; no
-- migration has ever altered it. So the RPC hands the constraint a value the
-- constraint rejects, the insert raises `23514`, and — because the strike is
-- one function body — the review event, the suppression and the demotion roll
-- back with it. **The strike does not half-apply, it fails entirely.**
--
-- Measured on production 2026-08-23 before writing this:
-- `calibration_labels` holds **0 rows** for `target_domain =
-- 'classification_parent'`. One of the six supervision domains has never
-- received a label, and it is the one covering the commonest classification
-- error there is — right entity, wrong parent.
--
-- **This is `0231`'s defect exactly, and the timing is worse.** There the
-- strike could never run and nothing noticed because `calibration_reads` was
-- `false` — *"it would have failed on the day the flag was turned on, which is
-- the worst day to find it."* That flag was turned on 2026-08-23 by `0316`.
-- The day has arrived.
--
-- **Widening the constraint rather than narrowing the RPC.** The other
-- direction was available: drop `wrong_parent` from `0294`'s allowlist and let
-- it fall back to `ambiguous_rejection`. That would restore agreement and
-- abandon the design — `classification_parent` exists as a supervision domain
-- precisely so a parent error is not read as a taste signal, and folding it
-- into `ambiguous_rejection` would price a classification mistake at −2.50
-- against the person's affinity. The constraint is what lagged; the constraint
-- is what moves.
--
-- **What this does not touch.** No price changes, no new domain, no reason
-- removed, and `ambiguous_rejection` remains the default — *"the honest
-- reading of one tap"* (`0203:336-337`). The fourteen existing values are
-- carried across unchanged and the migration proves it.

alter table semantic_private.review_events
  drop constraint review_events_reason_check;

alter table semantic_private.review_events
  add constraint review_events_reason_check check (reason = any (array[
    'correct',
    'wrong_entity',
    'wrong_type',
    'wrong_parent',
    'wrong_relation',
    'wrong_predicate',
    'over_propagated',
    'wrong_channel_role',
    'wrong_primary_term',
    'not_representative',
    'outdated',
    'too_private',
    'duplicate',
    'not_interested',
    'ambiguous_rejection'
  ]));

comment on constraint review_events_reason_check on semantic_private.review_events is
  'The reason vocabulary a review event may carry. Fifteen values: 0203 seeded '
  'fourteen and 0330 added wrong_parent, which 0294 had been able to send and '
  '0292 had been able to price since before it could be stored.';

do $$
declare
  installed text;
  admitted integer;
  refused boolean;
begin
  -- **The proof runs against the expression the catalog actually holds**, not
  -- against the text above. `0231`'s lesson is that a check on a function's
  -- source is not a check on its behaviour, and the honest reading of it here
  -- is to read the constraint back out and make it answer. The foreign keys on
  -- `review_events` are not deferrable, so a probe row cannot be inserted into
  -- the table itself without a user and a review item; a temporary table
  -- carrying the *installed* expression is what can be made to answer both
  -- ways inside this transaction.
  select pg_get_constraintdef(c.oid) into installed
    from pg_constraint c
   where c.conrelid = 'semantic_private.review_events'::regclass
     and c.conname = 'review_events_reason_check';

  if installed is null then
    raise exception '0330: the reason check is missing after the alter';
  end if;

  execute format(
    'create temporary table reason_probe (reason text not null %s) on commit drop',
    replace(installed, 'CHECK ', 'CONSTRAINT probe CHECK '));

  -- **Every one of the fifteen must be admitted**, which is what proves the
  -- fourteen that already worked were carried across rather than retyped from
  -- memory. A widening that quietly dropped `outdated` would look identical to
  -- a widening that did not, and only this count separates them.
  insert into reason_probe (reason)
  select unnest(array[
    'correct', 'wrong_entity', 'wrong_type', 'wrong_parent', 'wrong_relation',
    'wrong_predicate', 'over_propagated', 'wrong_channel_role',
    'wrong_primary_term', 'not_representative', 'outdated', 'too_private',
    'duplicate', 'not_interested', 'ambiguous_rejection']);

  select count(*) into admitted from reason_probe;
  if admitted <> 15 then
    raise exception '0330: the reason check admitted % of 15 values', admitted;
  end if;

  -- **And it must still refuse.** A constraint that has only ever been seen
  -- saying yes is not one to believe — the same demand `0306` makes of its own
  -- trigger. If widening had gone wrong in the other direction and admitted
  -- anything, every assertion above would still pass.
  refused := false;
  begin
    insert into reason_probe (reason) values ('not_a_reason');
  exception when check_violation then
    refused := true;
  end;
  if not refused then
    raise exception '0330: the reason check admits an unknown value';
  end if;

  -- **The two prices are now reachable.** They have existed since `0292` and
  -- described a value nothing could store; asserting the pair here is what
  -- makes this migration about the defect rather than about a constraint.
  if (select count(*) from semantic_private.calibration_label_prices
       where reason = 'wrong_parent') <> 2 then
    raise exception
      '0330: expected 2 wrong_parent prices from 0292, found %',
      (select count(*) from semantic_private.calibration_label_prices
        where reason = 'wrong_parent');
  end if;

  drop table reason_probe;
end;
$$;

-- **The end-to-end proof is not here.** A review event needs a user, a review
-- item and a candidate, and a migration that seeded those would be writing rows
-- into somebody's account to test itself. `0231` settled this shape: the
-- behavioural case lives in `supabase/tests/0230_calibration_lifecycle_contract.sql`,
-- which `tools/replay_contracts.sh` runs on every replay, and which this change
-- extends with a `wrong_parent` strike asserting that the label reaches
-- `classification_parent`.
