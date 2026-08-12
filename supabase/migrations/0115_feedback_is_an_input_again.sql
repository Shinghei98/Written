-- 0115 — feedback is an input again, because `0114` made it one.
--
-- **`0113` was right about the system it described and this changes that
-- system.** It dropped the revision bump on `feedback_events` because *"no
-- feedback action is an input to the scorer"* — the scorer did not read
-- `assertion_preferences`, so a suppression moved no number. `0114`'s transfer
-- reads exactly that table, so a suppression now changes what the scorer
-- computes, and a score computed before it is genuinely stale.
--
-- The rule `0113` states survives intact: **the revision moves when the
-- scorer's inputs move.** What changed is which writes are inputs.
--
--   `suppress`  — an input now: it redistributes weight. Bumps.
--   `restore`   — the same, in reverse. Bumps.
--   `confirm`   — nothing reads it yet. Does not bump.
--   `explicit_add` — adds a row with no observations and no mappings, which the
--                    scorer never sees. Does not bump, and this is what emptied
--                    the page when it did.
--
-- **The cost is honest and worth naming**: a suppression now stales the page
-- until the worker runs, which is the symptom `0111` and `0113` were written to
-- remove. It is a different trade rather than a regression — the score really
-- has changed, and showing the old one would be showing a number the system no
-- longer stands behind. What makes it survivable is that the recompute is
-- enqueued rather than waited for, and that is the next thing to build: nothing
-- yet enqueues on feedback, so today a suppression needs a manual worker run.
begin;

drop trigger if exists feedback_event_bump_semantic_revision
  on semantic_private.feedback_events;

create trigger feedback_event_bump_semantic_revision
after insert on semantic_private.feedback_events
for each row
when (new.action in ('suppress', 'restore'))
execute function semantic_private.bump_user_state_revision();

do $$
declare
  definition text;
begin
  select pg_get_triggerdef(t.oid) into definition
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal and c.relname = 'feedback_events'
     and t.tgname = 'feedback_event_bump_semantic_revision';
  if definition is null then
    raise exception 'the feedback revision trigger is missing';
  end if;
  -- The two that are inputs and neither of the two that are not. Asserted as
  -- the whole clause rather than as "contains suppress", because the failure
  -- worth catching is an action creeping back in.
  if definition not like '%WHEN ((new.action = ANY (ARRAY[''suppress''::text, ''restore''::text])))%' then
    raise exception 'the trigger fires for the wrong actions: %', definition;
  end if;
end
$$;

commit;
