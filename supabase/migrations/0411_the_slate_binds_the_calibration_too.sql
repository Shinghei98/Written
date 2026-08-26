-- 0411 — the slate binds the calibration too.
--
-- **The owner, 2026-08-26: "I never struck anything off" — and under
-- their own ruling, they are right.** The ledger's 3,646 votes are the
-- owner's, cast 2026-08-20/21 in the old Suggested-lane review; the
-- clean-slate ruling of 2026-08-25 ("as though it's the first time it
-- sees David's data", 0362) voided those judgments. The ledger is
-- append-only, so the votes rightly survive as history — but 0409's
-- release consumed them, resurrecting what the owner erased. The owner
-- asked to remove the votes; the append-only discipline forbids
-- deletion, and doesn't need it: **the publish gains a `votes_since`
-- boundary, recorded on the release row, and only votes cast after it
-- count.**
--
-- `release-bootstrap-3` publishes with the boundary at the slate
-- (2026-08-25): zero post-slate votes exist, so it carries zero
-- multiplier rows and every stratum resolves neutral — Memories scored
-- purely on evidence, the circuit built and waiting for the owner's
-- real strike pass on the current page. When that pass happens, one
-- publish call with the same boundary consumes only legitimate votes.

begin;

alter table semantic_private.calibration_releases
  add column votes_since timestamptz not null default 'epoch';

create or replace function semantic_private.publish_calibration_release(
  p_parameters text, p_release_version text,
  p_votes_since timestamptz default 'epoch')
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
    (version, parameters_version, decision_watermark, votes_since)
  values (p_release_version, p_parameters, watermark, p_votes_since)
  returning id into release_id;

  with votes as (
    select distinct l.user_id, l.review_item_id, l.independence_root,
           l.source_code, l.action_type, l.calibration_vote
      from semantic_private.calibration_feedback_ledger l
     where l.calibration_vote in ('positive', 'negative')
       -- 0411: the slate binds — votes before the boundary are history,
       -- never weight.
       and l.decided_at >= p_votes_since
  ), strata as (
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
    || ', votes since ' || p_votes_since || '): '
    || rows_published || ' multiplier row(s)');
  return release_id;
end;
$function$;

-- The two-parameter form retires; one signature, one meaning.
drop function if exists
  semantic_private.publish_calibration_release(text, text);

do $$
declare rid uuid;
begin
  select semantic_private.publish_calibration_release(
    'calibration_v1_bootstrap', 'release-bootstrap-3',
    '2026-08-25 00:00:00+00') into rid;
  raise notice '0411: release-bootstrap-3 published as % — slate-bounded, neutral until the real strike pass', rid;
end;
$$;

commit;
