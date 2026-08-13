-- 0138 — scorer 0.7.0: subscribed *and* liked is eligible outright.
--
-- **A rule, because no weight could have said it.** Calibrated on a real
-- account on 2026-08-13: `creator:le_sserafim` carries 109 mappings and a total
-- weight of 22.71 for a strength of 0.791, so one mapping contributes about
-- 0.21 after recency decay and evidence quality. The bar is `w/(w+6) >= 0.35`,
-- which needs `w >= 3.23` — roughly sixteen mappings. A lone subscription at
-- the current weight of 0.55 reaches a strength of 0.02, and **even at the
-- maximum weight of 1.0 it reaches 0.036**. No number in `action_weights` moves
-- a two-mapping creator across the bar, so raising the subscription weight
-- would have looked like a change and moved nothing.
--
-- **The two attestations are different in kind, not in amount.** A like is a
-- single act about a single video. A subscription is a standing relationship
-- somebody chose and has not undone. Their conjunction — followed *and* liked
-- their work — is the strongest statement this data can make, and it is rare:
-- on the account measured, three creators of the 109 with channel evidence.
--
-- **Deliberately not a lower bar for subscriptions alone.** That was the other
-- option and it is a much weaker claim: it would admit every channel somebody
-- followed once and forgot. The conjunction is what carries the information.
--
-- The precedent is `ELIGIBLE_STRENGTH_BY_KIND = {"work": 0.25}`, justified in
-- the same terms — "a creator accumulates across everything they touch while a
-- work is attested only by its own songs, so the same strength means more
-- evidence." This is that argument about attestation rather than kind.
--
-- **Why this migration exists at all.** Deploying scorer code re-scores
-- nothing: a run's identity is `(user, revision, ontology version, resolver,
-- scorer)` and the code version is not in it. `0135` learned this the
-- expensive way, enqueuing zero jobs after a policy change. A model version is
-- the lever, and a model version that lags its code makes `semantic_runs` state
-- something untrue.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.7.0'),
  'missing_aware_late_fusion', '0.7.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0, "eligible_strength": 0.35,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "work_eligible_strength": 0.25,'
  ' "subscribed_and_liked": "a YouTube concept attested by both a subscription'
  ' and a like is eligible regardless of strength; the conjunction is a'
  ' different kind of evidence, not a larger amount of one",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.6.0' and status = 'active';

do $$
declare
  active_scorers integer;
  newest text;
  enqueued integer;
begin
  select count(*) into active_scorers
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if active_scorers <> 1 then
    raise exception 'expected exactly one active scorer, found %', active_scorers;
  end if;

  select version into newest
  from ontology.model_versions
  where model_role = 'scorer' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.7.0' then
    raise exception 'finalization would pick scorer %, not 0.7.0', newest;
  end if;

  -- **The rule reads YouTube actions, so those actions must be weighted.**
  -- `AGGREGATE` sums `action_weights ->> o.action_type` and its `having`
  -- discards a concept whose total weight is zero — so a subscription with no
  -- weight would never reach the eligibility test at all, and the rule would be
  -- silently unreachable. Asserted rather than assumed, because that failure
  -- looks exactly like nobody having subscribed to anything.
  if not (
    select (action_weights ? 'subscription')
       and coalesce((action_weights ->> 'subscription')::double precision, 0) > 0
       and (action_weights ? 'liked_video')
    from semantic_private.sources where source_code = 'youtube'
  ) then
    raise exception
      'scorer 0.7.0 reads youtube subscription and liked_video weights that are not both present and positive';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.7.0: subscribed and liked is eligible outright'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for scorer 0.7.0', enqueued;
end
$$;

commit;
