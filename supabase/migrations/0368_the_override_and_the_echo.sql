-- 0368 — the override and the echo.
--
-- 0362 turned the Suggested lane off globally and the card stayed up for
-- exactly one account: the owner's, which carries a per-user
-- `feature_flag_overrides` row (`calibration_reads = true`) from the
-- surface's first rollout — and `flag_enabled_v031` reads the override
-- before the default, as designed. The override flips false rather than
-- being deleted: a row that says "decided off for this user" is a record,
-- an absent row is an accident waiting to be re-seeded.
--
-- And the hourglass came back because 0366 did what every
-- analysis-changing migration must — `enqueue_recompute_on_analysis_change`
-- — into a queue 0363 settled and nothing consumes; `memories_status`
-- counts any queued job as recomputing. The jobs settle `dead` as 0363's
-- did. The enqueue convention stands for the day a consumer returns; while
-- the pipeline runs from RIS, the queue must not hold what the RIS lane
-- delivers out of band. (The re-score these jobs represented is genuinely
-- owed — the folded i-dle label reads stale until it runs — and it runs
-- from RIS, not from here.)

begin;

update semantic_private.feature_flag_overrides
   set enabled = false
 where flag_key = 'calibration_reads'
   and user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'
   and enabled;

update semantic_private.worker_jobs
   set status = 'dead'
 where status in ('queued', 'running');

do $$
declare
  n integer;
begin
  if exists (
    select 1 from semantic_private.feature_flag_overrides
     where flag_key = 'calibration_reads'
       and user_id = 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'
       and enabled) then
    raise exception '0368: the calibration override still answers true';
  end if;
  select count(*) into n from semantic_private.worker_jobs
   where status in ('queued', 'running');
  if n > 0 then
    raise exception '0368: % job(s) still pending', n;
  end if;
  raise notice '0368: the override is off and the queue is quiet';
end;
$$;

commit;
