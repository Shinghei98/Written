-- 0105 — the re-score `0100` made necessary.
--
-- `0104` stops the revision moving for a close that changes nothing. It cannot
-- undo the nine bumps already taken: a revision is monotonic by design, and an
-- earlier value would be a lie about what has happened to somebody's data.
--
-- So the scores are recomputed at the revision that now stands. Until they are,
-- `api.list_assertions` withholds every inferred assertion — correctly, since
-- each was computed against an input the person's state no longer matches — and
-- the Memories surface is empty for a reason no reader could guess.
--
-- One job per affected user, keyed as always on the revision and the three
-- analysis ids, so a replay enqueues nothing.

begin;

do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    'rescore after 0100 advanced the state revision by closing unpromotable runs'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s)', enqueued;
end
$$;

commit;
