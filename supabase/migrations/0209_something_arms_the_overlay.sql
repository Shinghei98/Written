-- 0209 — something arms the overlay.
--
-- `0208` made the eight jobs enqueueable and nothing enqueues them.
-- `semantic_worker` cannot: it holds no privilege on `worker_jobs` beyond
-- reading and claiming, deliberately, because a worker that could enqueue for
-- itself could give itself work nobody asked for. Every other job in this
-- system is armed by a `security definer` function — `arm_vocabulary_mint` is
-- the precedent — and this is the overlay's.
--
-- ## Paced by what is already queued, not by a clock
--
-- The obvious arming key is a time bucket, and it is wrong here. Resolution is
-- batched at 2,000 mentions an invocation and the largest account holds 73,126,
-- so the pipeline needs roughly forty passes to drain once — and a time-bucketed
-- key would either enqueue forty jobs immediately, which is a queue nobody can
-- reason about, or one an hour, which is two days.
--
-- **So it enqueues only where nothing of that type is already waiting.** The
-- queue itself is the pacing mechanism: one job per user per stage in flight,
-- the next arming tops it up as EventBridge drains it, and the whole thing
-- settles at exactly the rate the worker can absorb. It also means calling this
-- twice is free, which is what lets it sit on a schedule.
--
-- ## Staggered, because the stages have an order
--
-- Resolution feeds candidates, candidates feed scores, scores feed the review
-- page. Enqueuing all four for one instant would run them in whatever order the
-- claim happened to take, and a `build_candidate_overlay` that ran before its
-- resolutions existed would simply find nothing — not wrong, but a wasted pass
-- and a receipt that reads like a failure. Ninety seconds apart puts them in
-- order against a two-minute drain without needing the worker to chain them,
-- which it cannot do.
--
-- ## What it does not arm
--
-- `extract_mentions`, because the contract disables the overlay and its handler
-- would decline — arming a job to be declined is noise in a queue that should
-- only hold work. `evaluate_release` and `aggregate_feedback` are operator and
-- fleet jobs with no per-user trigger. `build_review_items` is armed and its
-- epoch is `0`: nothing draws a review page yet, so every pass builds the same
-- first page, which `review_items_one_card_per_epoch` makes free after the
-- first. When a surface exists to advance the epoch, it advances it.

begin;

create or replace function semantic_private.arm_candidate_overlay(
  target_user uuid default null,
  resolver_version text default 'exact-0.1.0'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  armed integer := 0;
  stage_rows integer;
  stage record;
begin
  for stage in
    select * from (values
      ('resolve_mention',
       jsonb_build_object('resolver_version', resolver_version), 0),
      ('build_candidate_overlay', '{}'::jsonb, 90),
      ('aggregate_term_candidates', '{}'::jsonb, 180),
      ('build_review_items', jsonb_build_object('review_epoch', 0), 270)
    ) as s(job_type, extra, delay_seconds)
  loop
    insert into semantic_private.worker_jobs
      (job_type, user_id, payload, idempotency_key, available_at)
    select stage.job_type, u.id,
           stage.extra || jsonb_build_object('user_id', u.id::text),
           'overlay:' || stage.job_type || ':' || u.id::text || ':'
             || coalesce((select count(*)::text
                            from semantic_private.mention_resolutions r
                           where r.user_id = u.id), '0'),
           now() + make_interval(secs => stage.delay_seconds)
      from auth.users u
     where (target_user is null or u.id = target_user)
       -- Only where there is something for the pipeline to do at all.
       and exists (
         select 1 from semantic_private.observation_mentions m
          where m.user_id = u.id)
       -- **The pacing.** One of each stage in flight per user; the next call
       -- tops up whatever has drained.
       and not exists (
         select 1 from semantic_private.worker_jobs j
          where j.user_id = u.id
            and j.job_type = stage.job_type
            and j.status in ('queued', 'running'))
    on conflict (idempotency_key) do nothing;
    -- `get diagnostics` reports the *last* statement's rows, so it is read into
    -- a scratch variable and added. Assigning it straight to `armed` would make
    -- the function return whatever the final stage happened to enqueue.
    get diagnostics stage_rows = row_count;
    armed := armed + stage_rows;
  end loop;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_candidate_overlay(uuid, text)
  from public, anon, authenticated, semantic_ingestor;

-- **The worker may not call this.** It is the whole reason the function exists:
-- arming is an authority the thing doing the work must not hold.
revoke all on function semantic_private.arm_candidate_overlay(uuid, text)
  from semantic_worker;

do $$
declare
  armed integer;
  queued integer;
  refused boolean := false;
begin
  -- 1. It arms, and says how many.
  select semantic_private.arm_candidate_overlay() into armed;
  select count(*) into queued
    from semantic_private.worker_jobs
   where status = 'queued'
     and job_type in ('resolve_mention', 'build_candidate_overlay',
                      'aggregate_term_candidates', 'build_review_items');
  if queued = 0 then
    raise exception '0209: arming enqueued nothing and there are mentions to resolve';
  end if;

  -- 2. **Calling it twice is free**, which is what lets it sit on a schedule.
  --    A second call while the first batch is still queued must add nothing.
  select semantic_private.arm_candidate_overlay() into armed;
  if armed <> 0 then
    raise exception '0209: a second arming enqueued % more job(s)', armed;
  end if;

  -- 3. Every payload it wrote satisfies the registry `0208` installed. A job
  --    that fails validation is claimed and killed, so this is the check that
  --    matters most and it is asked of the rows themselves.
  if exists (
    select 1 from semantic_private.worker_jobs j
     where j.status = 'queued'
       and j.job_type in ('resolve_mention', 'build_candidate_overlay',
                          'aggregate_term_candidates', 'build_review_items')
       and not semantic_private.worker_job_payload_is_valid_v03(
             j.job_type, j.user_id, j.payload)
  ) then
    raise exception '0209: an armed payload does not satisfy its own contract';
  end if;

  raise notice '0209: % overlay job(s) queued across the fleet', queued;
end;
$$;

commit;
