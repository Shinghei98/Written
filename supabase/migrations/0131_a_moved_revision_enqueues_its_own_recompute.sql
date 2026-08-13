-- 0131 — the half `0115` left owed: a moved revision asks for its own re-score.
--
-- **Observed for real on 2026-08-13.** The owner suppressed one term in
-- Memories at 02:19:00.076479; `user_state_versions.updated_at` moved in the
-- same microsecond; and every one of that account's 65 inferred assertions
-- disappeared from the page, leaving only the entries they had typed
-- themselves. Nothing was broken: `api.list_assertions` requires a score
-- computed at the current revision for anything inferred, the newest score sat
-- at 28, and the revision had moved to 29.
--
-- `0114` made suppression a real scorer input and `0115` correctly restored the
-- revision bump to match — and both stopped there. The gap was recorded the
-- same day: *"nothing enqueues a recompute when somebody answers a claim, so
-- the Memories page stays blank until the worker is run by hand."* That is
-- exactly what happened, to the person who wrote it down.
--
-- **The trigger goes on `user_state_versions`, not on `feedback_events`.**
-- Enqueuing from the feedback table would mean restating which actions are
-- scorer inputs — `0115` decided suppress and restore are, confirm and
-- `explicit_add` are not — and a second copy of that rule is a second thing to
-- keep in step. Seven triggers across six tables move this revision; hanging
-- the recompute off the *movement* cannot disagree with any of them, and covers
-- causes nobody has thought of yet.
--
-- **Idempotent by the key, which is why double-enqueuing is safe.**
-- `finalize_ingestion_run_v031` already enqueues after a distillation, so an
-- ingestion bump now asks twice; the job key carries the revision and all three
-- analysis ids, so the second call adds nothing. `0093` chose that key for
-- precisely this reason.
--
-- **The cost, stated plainly.** Suppressing five terms in a row moves the
-- revision five times and enqueues five jobs, because each one genuinely
-- changes what the scorer computes. The alternative — debouncing — would mean
-- deciding how long to leave somebody's page stale, which is a worse question
-- than doing the work.

begin;

create or replace function private.enqueue_recompute_on_revision_move()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.revision is distinct from old.revision then
    -- Per user, not fleet-wide: this fires on one person's action and the
    -- function skips anybody a run already covers, so passing the id keeps a
    -- single tap from scanning every account.
    perform semantic_private.enqueue_recompute_on_analysis_change(
      'revision moved', new.user_id
    );
  end if;
  return new;
end;
$$;

comment on function private.enqueue_recompute_on_revision_move() is
  'A moved state revision stales every inferred assertion for that user, so it '
  'asks for the re-score that unstales them. On user_state_versions rather than '
  'on feedback_events so it cannot disagree with whichever of the seven bump '
  'triggers fired.';

drop trigger if exists user_state_versions_enqueue_recompute
  on semantic_private.user_state_versions;
create trigger user_state_versions_enqueue_recompute
after update on semantic_private.user_state_versions
for each row execute function private.enqueue_recompute_on_revision_move();

revoke all on function private.enqueue_recompute_on_revision_move()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The account this already happened to
-- ---------------------------------------------------------------------------
--
-- The trigger only fires on future moves, and the revision is monotonic — an
-- earlier value would be a lie about what has happened, which is why `0104`
-- refused to walk one back and `0105` re-scored instead. So anybody already
-- stranded is enqueued here, by the same call the trigger makes.
do $$
declare
  stranded uuid;
  enqueued integer;
  total integer := 0;
begin
  for stranded in
    select s.user_id
      from semantic_private.user_state_versions s
     where not exists (
       select 1 from semantic_private.semantic_runs r
        where r.user_id = s.user_id
          and r.status = 'succeeded'
          and r.input_revision = s.revision
     )
  loop
    select semantic_private.enqueue_recompute_on_analysis_change(
      'stranded by a revision move before 0131', stranded
    ) into enqueued;
    total := total + coalesce(enqueued, 0);
  end loop;
  raise notice 'enqueued % recompute job(s) for stranded accounts', total;
end
$$;

-- **Behaviour, and it can fail.** Asserting the trigger exists would prove
-- nothing; this asserts that a stranded account now has work queued, which is
-- the property the page depends on.
do $$
declare
  stranded integer;
  queued integer;
begin
  select count(*) into stranded
    from semantic_private.user_state_versions s
   where not exists (
     select 1 from semantic_private.semantic_runs r
      where r.user_id = s.user_id and r.status = 'succeeded'
        and r.input_revision = s.revision
   );

  if stranded = 0 then
    raise notice 'no stranded accounts; nothing to queue';
    return;
  end if;

  -- **Counted by what the job is *for*, not by its status.** The first draft
  -- looked for `status in ('pending','running')` and found nothing — because
  -- the vocabulary is `queued | running | succeeded | failed | dead` and
  -- `pending` is not in it. The enqueue had worked; the check was wrong, and it
  -- rolled the whole migration back. A status word guessed rather than read is
  -- the same defect as `0125` reading the wrong surface, one table over.
  --
  -- Matching on the stranded revision is also the stronger test: a job left
  -- over from an earlier revision would satisfy a status count and would not
  -- unstale anybody.
  select count(*) into queued
    from semantic_private.worker_jobs j
    join semantic_private.user_state_versions s on s.user_id = j.user_id
   where j.job_type = 'recompute_user'
     and (j.payload ->> 'input_revision')::bigint = s.revision
     and j.status in ('queued', 'running');

  raise notice '% stranded account(s), % job(s) queued at the current revision',
    stranded, queued;
  if queued = 0 then
    raise exception
      '% account(s) are stranded and nothing is queued at their revision', stranded;
  end if;
end
$$;

commit;
