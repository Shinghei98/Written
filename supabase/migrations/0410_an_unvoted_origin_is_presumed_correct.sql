-- 0410 — an unvoted origin is presumed correct.
--
-- **The owner's ruling, 2026-08-26, closing the question 0409 opened.**
-- The first release carried a global fallback row — all votes pooled,
-- 46 keeps / 397 strikes, multiplier 0.5 — that caught every stratum
-- nobody had voted on. Observed on Timi's page: her Spotify evidence,
-- which no vote has ever touched, halved wholesale on the strength of
-- the calibrator's Apple-Music strikes. The owner's own standing rule
-- decides it: **every term is presumed correct until struck**, and the
-- global row smuggled the opposite presumption in at the weight layer —
-- with cutoffs fitted, that would be the Suggested lane returning
-- through arithmetic.
--
-- So the publish loses the global grouping set. What remains:
-- exact (source, action) strata and the per-source rollups — both
-- derived from votes actually cast about that source. An origin with no
-- votes resolves through `calibration_multiplier`'s final coalesce to
-- 1.0: absence is neutrality, now in fact as well as in the comment.
--
-- `release-bootstrap-2` publishes under the same bootstrap parameters,
-- retiring bootstrap-1 (immutable, kept). The publish enqueues the
-- recomputes; the consumer drains them.

begin;

create or replace function semantic_private.publish_calibration_release(
  p_parameters text, p_release_version text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  prm record;
  watermark timestamptz;
  release_id uuid;
  rows_published integer;
begin
  select * into strict prm
    from semantic_private.calibration_parameters where version = p_parameters;
  select coalesce(max(decided_at), 'epoch'::timestamptz) into watermark
    from semantic_private.calibration_effective_decisions;

  update semantic_private.calibration_releases
     set status = 'retired' where status = 'active';

  insert into semantic_private.calibration_releases
    (version, parameters_version, decision_watermark)
  values (p_release_version, p_parameters, watermark)
  returning id into release_id;

  with votes as (
    select distinct l.user_id, l.review_item_id, l.independence_root,
           l.source_code, l.action_type, l.calibration_vote
      from semantic_private.calibration_feedback_ledger l
     where l.calibration_vote in ('positive', 'negative')
  ), strata as (
    -- 0410: no global grouping set. An origin nobody voted on stays
    -- neutral — presumed correct until struck, the owner's rule.
    select v.source_code, v.action_type,
           count(*) filter (where v.calibration_vote = 'positive') as keeps,
           count(*) filter (where v.calibration_vote = 'negative') as strikes,
           count(distinct v.user_id) as distinct_users
      from votes v
     group by grouping sets ((v.source_code, v.action_type),
                             (v.source_code))
  )
  insert into semantic_private.calibration_release_multipliers
    (release_id, source_code, action_type, keeps, strikes,
     distinct_users, multiplier)
  select release_id, s.source_code, s.action_type, s.keeps, s.strikes,
         s.distinct_users,
         least(greatest(
           ((s.keeps + prm.alpha) / (s.keeps + s.strikes + prm.alpha + prm.beta))
             / (prm.alpha / (prm.alpha + prm.beta)),
           prm.min_multiplier), prm.max_multiplier)
    from strata s
   where s.distinct_users >= prm.min_distinct_users
     and (s.keeps + s.strikes) > 0
     and s.source_code is not null;
  get diagnostics rows_published = row_count;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'calibration release ' || p_release_version || ' (' || p_parameters
    || '): ' || rows_published || ' multiplier row(s), unvoted origins neutral');
  return release_id;
end;
$function$;

do $$
declare rid uuid;
begin
  select semantic_private.publish_calibration_release(
    'calibration_v1_bootstrap', 'release-bootstrap-2') into rid;
  raise notice '0410: release-bootstrap-2 published as % — global fallback gone', rid;
end;
$$;

commit;
