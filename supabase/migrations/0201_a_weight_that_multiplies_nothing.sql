-- 0201 — a weight that multiplies nothing, said so beside the number.
--
-- ## The question this answers, because it was asked
--
-- `semantic_private.sources.action_weights` for HealthKit reads:
--
--     {"activity_day":0.0,"activity_hour":0.0,"workout":0.0,"sleep":0.0,"routine":0.85}
--
-- and four zeros beside one real number look exactly like a tuning nobody got
-- round to. They are not. **Raising `workout` above 0.0 changes nothing at all**,
-- because the weight multiplies a mapping that cannot exist, and two independent
-- mechanisms make sure of it:
--
-- - `ObservationMapper._source_projection_is_valid` (`mapping.py:108`) admits a
--   HealthKit observation only where `data_type = 'fitness_habit'`,
--   `action = 'routine'`, `privacy_class = 'private_fitness_sanitized'` and
--   `allow_external_resolution` is false, with an exact metadata shape and
--   exactly one term. A `workout` row fails on the second clause.
-- - `guard_healthkit_observation_mapping` says it again in the database, from
--   the other side: every HealthKit mapping must match a **current validated
--   fitness habit candidate**, with `evidence_weight` pinned to 1.0,
--   `mapping_method = 'provider_metadata'`, `candidate_rank = 1` and
--   `data_use_purpose = 'fitness_connection'`.
--
-- `0046` wrote the reason down when it set these: *"Raw HealthKit ingestion is
-- active, but only the thresholded fitness_habit / routine projection has
-- nonzero semantic weight. Daily/hourly/workout/sleep records themselves cannot
-- be mapped by the generic mapper."*
--
-- ## So workouts do count, and this is where
--
-- **A workout is not the evidence; the habit derived from workouts is.**
-- `healthkit_fitness_habit_builder` needs **4 sessions across 3 distinct weeks
-- inside a 42-day window** before it nominates anything, and what it nominates
-- arrives as `action = 'routine'` at **0.85** — higher than every Apple Music
-- action except a rating, higher than a YouTube subscription, and above all but
-- seven of the roughly fifty action weights in the system.
--
-- **The dial that says "how much does a workout count" is therefore
-- `workout_min_sessions` / `workout_min_weeks` on the builder, not
-- `action_weights.workout`.** Moving it is a decision about how much evidence a
-- habit needs, and it is deliberately not made here: there are **zero HealthKit
-- observations in the vault** and no device in this project has recorded a
-- workout, so any new threshold would be a constant fitted to no data points —
-- which is the mistake `score.py` was careful not to make when it set the work
-- bar from three labelled rows rather than from none.
--
-- ## Why the zeros stay
--
-- Deleting them would change no behaviour — `coalesce((action_weights ->> …), 0.0)`
-- answers 0.0 for an absent key just as it does for a present zero — and would
-- lose the only place the refusal is stated as data. **A zero that is written
-- down is a decision; a missing key is an oversight**, and these are decisions.
-- So they stay, and this migration adds the sentence that stops them reading as
-- the other thing.
--
-- Nothing executable changes. That is the point: the defect was in what a reader
-- would conclude, and the repair belongs in the same place as the number.

begin;

comment on column semantic_private.sources.action_weights is
  'Per action: how much one act of that kind weighs as evidence. '
  'A zero is a decision, not an unset default. HealthKit''s activity_day, '
  'activity_hour, workout and sleep are zero because those rows cannot be '
  'mapped at all — ObservationMapper._source_projection_is_valid admits only '
  'data_type = fitness_habit with action = routine, and '
  'guard_healthkit_observation_mapping requires a match against a current '
  'validated fitness habit candidate. Raising them changes nothing; the dial '
  'for how much a workout counts is workout_min_sessions / workout_min_weeks '
  'on healthkit_fitness_habit_builder. Calendar''s booked, cancelled and '
  'entered_by_user are zero for the same shape of reason: calendar rows reach '
  'the scorer through the classifier, never the generic mapper.';

do $$
declare
  healthkit_zeroes integer;
  routine_weight   double precision;
begin
  -- **The state the comment describes, asserted rather than assumed.** If a
  -- later migration raises one of these to a nonzero value, whoever does it
  -- should have to change this line too and read the sentence above while doing
  -- so — which is the whole value of pinning a fact nobody expects to move.
  select count(*) into healthkit_zeroes
    from semantic_private.sources s,
         lateral jsonb_each_text(s.action_weights) as a(action, weight)
   where s.source_code = 'healthkit'
     and a.action in ('activity_day', 'activity_hour', 'workout', 'sleep')
     and a.weight::double precision = 0.0;
  if healthkit_zeroes <> 4 then
    raise exception '0201: expected four unmappable HealthKit actions at zero, found %',
      healthkit_zeroes;
  end if;

  select (s.action_weights ->> 'routine')::double precision into routine_weight
    from semantic_private.sources s where s.source_code = 'healthkit';
  if routine_weight is null or routine_weight <= 0.0 then
    raise exception '0201: the one mappable HealthKit action weighs %, so HealthKit contributes nothing',
      coalesce(routine_weight::text, '(absent)');
  end if;

  raise notice '0201: HealthKit contributes through routine at %, and four unmappable actions stay at zero',
    routine_weight;
end;
$$;

commit;
