-- 0210 — a dead job blocks its own replacement.
--
-- ## What went wrong, measured
--
-- `0209` arms the overlay with an idempotency key of
-- `overlay:<stage>:<user>:<count of that user's mention_resolutions>`. The count
-- is what advances the key as work is done, and it is the right thing to key on
-- while work is being done.
--
-- It is the wrong thing when work has *not* been done. `resolve_mention` failed
-- five times against a bug in its own SQL — `min(uuid)`, which Postgres has no
-- aggregate for — and was marked `dead`. The fix shipped; re-arming did nothing.
-- The resolution count was still zero, so the key was byte-identical to the dead
-- row's, `on conflict (idempotency_key) do nothing` did exactly what it says, and
-- the pipeline sat still while every part of it worked.
--
-- **The failure mode is the one this project keeps meeting: silence.** Arming
-- returned 0, which is also what it returns when everything is already queued,
-- so nothing anywhere distinguished "no work needed" from "cannot enqueue the
-- work that is needed".
--
-- ## Two changes, and only one of them is the fix
--
-- `clear_dead_overlay_jobs` deletes dead overlay rows. **A queue row is not
-- evidence** — "nothing in Postgres is ever deleted" is about the distillation
-- record and the vault, not about operational debris — and a dead row's whole
-- content is a job type, a user, a closed payload and the string
-- `handler_error`. Deleting it is how a fixed bug becomes a job that runs again.
--
-- It is deliberately **not** called by the schedule. A dead job means five
-- consecutive failures, and a scheduler that quietly resurrected it would retry
-- a real defect forever at two-minute intervals while reporting nothing. Clearing
-- is an operator's act, after the operator has fixed something.
--
-- The second change is the one that makes the first unnecessary next time:
-- **arming now says how many users it could not arm because of a dead job.** A
-- return of `0` armed and `1` blocked is a different sentence from `0` armed and
-- `0` blocked, and the schedule logs it.
--
-- ## The schedule
--
-- `0209`'s header said the pacing was "what lets it sit on a schedule" and then
-- did not create one, so the pipeline ran exactly once. Draining one account's
-- 73,126 mentions at 2,000 an invocation is about forty passes; at every five
-- minutes that is a little over three hours, unattended, which is the right
-- shape for work nothing is waiting on.

begin;

create or replace function semantic_private.clear_dead_overlay_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleared integer;
begin
  delete from semantic_private.worker_jobs
   where status = 'dead'
     and job_type in ('extract_mentions', 'resolve_mention',
                      'build_candidate_overlay', 'aggregate_term_candidates',
                      'build_review_items', 'apply_feedback',
                      'aggregate_feedback', 'evaluate_release');
  get diagnostics cleared = row_count;
  return cleared;
end;
$$;

revoke all on function semantic_private.clear_dead_overlay_jobs()
  from public, anon, authenticated, semantic_ingestor, semantic_worker;

-- **Arming reports what it could not do.** Same body as `0209` otherwise; the
-- difference is the `blocked` count and the notice, so a scheduled call that
-- achieves nothing says which kind of nothing it was.
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
  blocked integer;
  stage record;
begin
  select count(distinct j.user_id) into blocked
    from semantic_private.worker_jobs j
   where j.status = 'dead'
     and j.job_type in ('resolve_mention', 'build_candidate_overlay',
                        'aggregate_term_candidates', 'build_review_items')
     and (target_user is null or j.user_id = target_user);

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
       and exists (
         select 1 from semantic_private.observation_mentions m
          where m.user_id = u.id)
       and not exists (
         select 1 from semantic_private.worker_jobs j
          where j.user_id = u.id
            and j.job_type = stage.job_type
            and j.status in ('queued', 'running'))
    on conflict (idempotency_key) do nothing;
    get diagnostics stage_rows = row_count;
    armed := armed + stage_rows;
  end loop;

  if blocked > 0 then
    raise notice
      'arm_candidate_overlay: % job(s) armed; % account(s) blocked by a dead '
      'job. Fix the cause, then call semantic_private.clear_dead_overlay_jobs().',
      armed, blocked;
  end if;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_candidate_overlay(uuid, text)
  from public, anon, authenticated, semantic_ingestor, semantic_worker;

-- ---------------------------------------------------------------------------
-- Clear what the `min(uuid)` bug left, and start the schedule.
-- ---------------------------------------------------------------------------

do $$
declare
  cleared integer;
  armed integer;
begin
  select semantic_private.clear_dead_overlay_jobs() into cleared;
  raise notice '0210: cleared % dead overlay job(s)', cleared;

  select semantic_private.arm_candidate_overlay() into armed;
  raise notice '0210: armed % overlay job(s)', armed;

  -- **The clearing must have unblocked something**, or this migration is
  -- describing a state that is not the one it found. If nothing was dead there
  -- was nothing to fix, and if something was dead the re-arm must now succeed.
  if cleared > 0 and armed = 0 then
    raise exception
      '0210: % dead job(s) cleared and nothing re-armed — the key still collides',
      cleared;
  end if;
end;
$$;

select cron.schedule(
  'overlay-arm',
  '*/5 * * * *',
  $$select semantic_private.arm_candidate_overlay()$$
);

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'overlay-arm') then
    raise exception '0210: the arming schedule was not created';
  end if;
  raise notice '0210: overlay-arm scheduled every five minutes';
end;
$$;

commit;
