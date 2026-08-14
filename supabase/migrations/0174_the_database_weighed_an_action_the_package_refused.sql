-- 0174 — the database weighed an action the package refused.
--
-- ## What was measured
--
-- 2026-08-14, one account's Spotify library:
--
-- | data_type | observations | action_weight | mapped |
-- |---|---|---|---|
-- | `saved_track` | 500 | 0.60 | 73 |
-- | `top_track` | 500 | **0.78** | **0** |
-- | `top_artist` | 60 | **0.55** | **0** |
-- | `followed_artist` | 20 | 0.55 | 4 |
--
-- 560 observations, correctly weighted by this database, correctly projected,
-- payloads indistinguishable in shape from the `saved_track` rows beside them —
-- and not one mapping between them. The rank-1 `top_artist` row is literally
-- `{"primary_performer": "Jay Chou"}`, and `creator:jay_chou` is one of the
-- three concepts that *did* clear the eligibility bar on that account.
--
-- ## The cause: one fact in two places
--
-- `0139` weighed `top_track` at 0.78 and `top_artist` at 0.55 in
-- `semantic_private.sources.action_weights`. It did not touch
-- `written_ontology.source_policy.SOURCE_ACTION_WEIGHTS`, and it could not have
-- — that table lives in the package, not in the database.
--
-- Both copies are consulted, at different points, for different questions:
--
-- * **The database's copy** is stamped onto every observation at ingestion as
--   `observations.action_weight`. It was right. That is why the rows *look*
--   correct from SQL, and why this went unnoticed for six migrations.
-- * **The package's copy** derives `SOURCE_ACTION_PAIRS`, and
--   `ObservationMapper` refuses any action absent from it. It was wrong.
--
-- And a third gate behind them: `DEFAULT_RECENCY_POLICY` had no rule for either
-- action, so `rule_for` raised `unsupported_recency_key`, which `resolve.py`
-- catches and counts as `unweighted_action` before `continue`. The comment on
-- that handler asserted *"`recommendation` is the only action this hits"* — a
-- sentence that was true when written and made the counter unreadable
-- afterwards. `unweighted_action` sat at exactly 102 across every run while the
-- run's own metrics reported success.
--
-- ## What changed in the package
--
-- * `SOURCE_ACTION_WEIGHTS['spotify']` gains `top_track` 0.78 and `top_artist`
--   0.55 — **mirroring this database exactly**, because two answers to "what is
--   this act worth" is the defect rather than either number.
-- * A new recency rule, `music.top.medium_term`. Spotify's `/me/top/*` is a
--   ranking of a six-month window rather than an event and carries no timestamp
--   at all, so `unknown_timestamp_weight` is the only value it will ever
--   produce. It is 0.70, matched to `ENDURING_LIBRARY`: the action weight
--   already says a top track is the strongest listening signal a music source
--   gives us, and recency answers *how stale*, not *how much it means*.
-- * `test_source_policy` and `test_recency` both pin exact sets, so neither
--   change could be made on one side alone — which is how this migration exists
--   at all.
--
-- **`RECENCY_POLICY_VERSION` is deliberately not bumped.** No previously
-- supported key computes differently; the policy answers for keys it used to
-- refuse. Rows are already distinguishable at finer grain than a policy version
-- would give: `observation_mappings.recency_rule_id` carries
-- `music.top.medium_term` on exactly the rows this adds.
--
-- ## Why a model version, when an ontology version is also moving
--
-- `0173` publishes ontology 0.22.0, which alone forces a fresh run — the run
-- identity is `(user, revision, ontology version, resolver, scorer)`. So the
-- recompute would happen regardless.
--
-- The bump is not about forcing the run. It is that **resolver 0.9.0 would
-- otherwise name two different behaviours**: the one that discarded 560
-- observations and the one that does not. A model version that lags its code
-- makes `semantic_runs` state something untrue about work it has already
-- recorded, and every run before today claiming 0.9.0 did the old thing.
--
-- **This migration does not deploy anything.** The package ships inside the
-- worker's zip, so `aws/worker/build.sh` must run and the Lambda must be
-- updated; applying this against an undeployed worker registers a version whose
-- behaviour is not yet live. Apply it after the deploy, not before.

begin;

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select gen_random_uuid(), 'ontology_first_resolver', '0.10.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'spotify_top_items',
         'top_track and top_artist are mapped. They carried an action weight '
         || 'from 0139 and were refused by SOURCE_ACTION_PAIRS, which had never '
         || 'been told of them, and again by the recency policy, which had no '
         || 'rule. Recency rule music.top.medium_term, unknown-timestamp weight '
         || '0.70 — these rankings never carry a timestamp, so that is the only '
         || 'value it produces.'
       ),
       'active'
  from ontology.model_versions old
 where old.model_key = 'ontology_first_resolver' and old.version = '0.9.0';

do $$
declare
  actives  integer;
  enqueued integer;
begin
  -- **Asked rather than assumed.** `0171` introduces 0.9.0 and is applied
  -- separately; if it has not been, the insert above selected no row and this
  -- migration would otherwise leave the resolver retired and no version active,
  -- which stops every future run with nothing naming the cause.
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception
      '0174: expected exactly one active resolver, found % — apply 0171 first',
      actives;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.10.0: the database weighed an action the package refused'
         ) into enqueued;
  raise notice '0174: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
