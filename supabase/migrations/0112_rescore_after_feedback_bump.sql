-- 0112 — the one account `0111` could not repair.
--
-- `0111` stops a confirmation or suppression invalidating somebody's scores.
-- It cannot undo the bump already taken: the demo account sits at revision 10
-- against a run computed at 9, so `api.list_assertions` correctly withholds
-- every inferred assertion and its Memories card is blank.
--
-- **That account is the one a reviewer signs into**, which is the reason this
-- is worth a migration rather than being left for the next distillation.
begin;
do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    'rescore after a feedback event bumped the revision, before 0111'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s)', enqueued;
end
$$;
commit;
