-- 0328 — the archive sweep gets a schedule.
--
-- `0327` wrote `sweep_youtube_raw_archives` and scheduled nothing, which makes
-- it a function that would have sat there being correct while raw YouTube
-- bodies aged past thirty days in the bucket. **A retention obligation with no
-- cron entry is a claim in a document, not a behaviour**, and this project's
-- standing defect is exactly that shape: a call that can fail, a result nobody
-- reads, and the symptom surfacing somewhere else.
--
-- **Its own job rather than a third column on `sweep_youtube_retention`.**
-- That function returns `table (records_deleted bigint, cards_touched bigint)`,
-- and `create or replace` does not replace a function whose signature changed —
-- it *overloads* it, leaving an ambiguity Postgres refuses with `42725` from
-- inside whatever calls it. Changing its shape means `drop function` naming the
-- old signature in full, which would drop the running cron entry's target
-- mid-schedule. Two jobs is the cheaper truth.
--
-- **Twelve minutes after the other one**, so the two are legible in the log as
-- separate work rather than racing for the same rows — they touch different
-- tables, but a shared minute makes a slow night look like one stuck job.

select cron.schedule(
    'youtube-raw-archive-retention',
    '29 3 * * *',
    $$select public.sweep_youtube_raw_archives()$$
);

do $$
declare
    scheduled integer;
begin
    -- **Asserted, because a `cron.schedule` that silently did nothing is the
    -- failure this migration exists to correct.** The job either exists under
    -- that name or the retention claim is still unkept.
    select count(*) into scheduled from cron.job
     where jobname = 'youtube-raw-archive-retention';
    if scheduled <> 1 then
        raise exception
            '0328: the archive retention job is not scheduled (found %)', scheduled;
    end if;

    -- And the older one is still there: adding a job must not have disturbed
    -- the sweep that covers `distilled_records` and the discovery cards.
    select count(*) into scheduled from cron.job
     where jobname = 'youtube-retention';
    if scheduled <> 1 then
        raise exception
            '0328: the original YouTube retention job is missing (found %)',
            scheduled;
    end if;

    raise notice '0328: both YouTube retention jobs are scheduled';
end;
$$;
