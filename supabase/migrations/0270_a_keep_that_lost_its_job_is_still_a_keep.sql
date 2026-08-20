-- 0270 — a keep whose job died is still a keep.
--
-- The enqueue behind a mint request fires once, on insert. A dead job does
-- not retry and blocks its own re-arm by identical idempotency key (`0210`,
-- with its sweeper deliberately unscheduled) — so the five requests the owner
-- authorised this afternoon are `pending` for ever, with nothing left that
-- would ever look at them again. The keeps are recorded, the vocabulary they
-- authorise is not minted, and no surface says so.
--
-- That is a gap in the design rather than in today's run: **the trigger is an
-- optimisation, and the pending row is the truth.** Anything that only fires
-- on insert cannot recover from the one thing queues actually do.
--
-- So the armer gains a stage that asks the question the trigger answers only
-- once: is there a pending mint request with no live job? Its key carries a
-- cursor, exactly as `0211` does for the overlay stages, so a dead attempt is
-- followed by a fresh key rather than a permanently claimed one.
--
-- The handler drains every pending request it can lock regardless of which
-- one the payload names, so one job clears the backlog; the named request is
-- provenance.

create or replace function semantic_private.arm_pending_mint_requests()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  armed integer := 0;
  request_row record;
  next_count bigint;
begin
  -- One job while any request is pending, not one per request: the handler
  -- drains them all. The oldest is named because provenance should point at
  -- the decision that has waited longest.
  select mr.id into request_row
    from semantic_private.mint_requests mr
   where mr.status = 'pending'
     and not exists (
       select 1 from semantic_private.worker_jobs j
        where j.job_type = 'process_mint_requests'
          and j.status in ('queued', 'running'))
   order by mr.created_at
   limit 1;

  if request_row.id is null then
    return 0;
  end if;

  -- **The cursor is what makes a retry possible at all.** `0210`'s rule is
  -- that a dead row holds its key; a counter in the key means the next arming
  -- is a different job rather than a conflict silently doing nothing.
  --
  -- Counted from the jobs themselves rather than kept in
  -- `overlay_stage_cursors`, whose `user_id` is `not null` — this stage has no
  -- user, because minting writes shared vocabulary. Dead rows are never
  -- removed, so the count only rises and a key is never reused.
  select count(*) + 1 into next_count
    from semantic_private.worker_jobs
   where job_type = 'process_mint_requests';

  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  values ('process_mint_requests', null,
          jsonb_build_object('mint_request_id', request_row.id),
          'mint:v1:' || next_count::text,
          now())
  on conflict (idempotency_key) do nothing;

  get diagnostics armed = row_count;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_pending_mint_requests()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.arm_pending_mint_requests()
  to semantic_worker;

-- Appended to the overlay armer, `0247`'s pattern: one thing arms the lane,
-- and a second scheduler would be a second place to look when it is idle.
do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.arm_candidate_overlay(uuid, text)'::regprocedure);

  if position('arm_pending_mint_requests' in body) > 0 then
    raise notice '0270: the armer already arms the mint processor';
    return;
  end if;

  patched := regexp_replace(
    body,
    E'(\n  )return armed;',
    E'\\1perform semantic_private.arm_pending_mint_requests();\\1return armed;');
  if patched = body then
    raise exception '0270: the armer has no return to append to';
  end if;
  execute patched;
end;
$$;

do $$
begin
  if position('arm_pending_mint_requests' in
              pg_get_functiondef(
                'semantic_private.arm_candidate_overlay(uuid, text)'::regprocedure)) = 0 then
    raise exception '0270: the armer does not arm the mint processor';
  end if;

  -- **Both ways, over whatever this database holds.** With no pending request
  -- it must arm nothing — the same answer on an empty replay database as in
  -- production once the backlog clears — and with one it must arm exactly one
  -- job, which the production run after this migration demonstrates.
  if exists (select 1 from semantic_private.mint_requests where status = 'pending')
  then
    if semantic_private.arm_pending_mint_requests() <> 1 then
      raise exception '0270: a pending request did not arm the processor';
    end if;
    -- And not twice while that job is live.
    if semantic_private.arm_pending_mint_requests() <> 0 then
      raise exception '0270: the processor was armed twice for one backlog';
    end if;
  else
    if semantic_private.arm_pending_mint_requests() <> 0 then
      raise exception '0270: the processor armed with nothing pending';
    end if;
  end if;
end;
$$;
