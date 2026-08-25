-- 0363 — the queue stops promising what nothing runs.
--
-- **The hourglass on Memories was a promise with no worker behind it.**
-- `api.memories_status` reports `recomputing` whenever a queued job exists
-- for the user, and pg_cron has been arming the candidate-overlay chain
-- every five minutes (`overlay-arm`) and the catalogue drain every ten
-- (`catalogue-drain`) since the AWS worker went quiet — jobs nothing
-- consumes, accumulating since 2026-08-21, keeping the recomputing card up
-- forever. The pipeline runs from RIS now (`tools/run_worker_stages.py`),
-- out of band of this queue, and the Suggested lane those cron jobs fed
-- went dark in `0362`.
--
-- Three settlements, all reversible:
--
-- 1. **The two armers unschedule.** The functions stay; re-enabling is one
--    `cron.schedule` call the day a consumer exists again.
-- 2. **Every queued job goes `dead`** — the vocabulary's word for "claimed
--    by no handler", which is exactly what these are. Not deleted: the
--    rows record what was armed and when.
-- 3. Nothing else moves. `memories_status` keeps its meaning — it will now
--    answer honestly, because the queue only holds work that is really
--    pending.

begin;

select cron.unschedule('overlay-arm');
select cron.unschedule('catalogue-drain');

update semantic_private.worker_jobs
   set status = 'dead'
 where status in ('queued', 'running');

do $$
declare
  armed integer;
  pending integer;
begin
  select count(*) into armed from cron.job
   where jobname in ('overlay-arm', 'catalogue-drain');
  if armed > 0 then
    raise exception '0363: % armer(s) still scheduled', armed;
  end if;
  select count(*) into pending from semantic_private.worker_jobs
   where status in ('queued', 'running');
  if pending > 0 then
    raise exception '0363: % job(s) still pending', pending;
  end if;
  raise notice '0363: the queue is settled and the armers are quiet';
end;
$$;

commit;
