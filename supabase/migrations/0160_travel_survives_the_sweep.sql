-- 0160 — a trip must be exempt from the sweep that retires unscored claims.
--
-- **`0159` asserted two trips and the scorer retired both within the same
-- transaction.** `DEMOTE_UNSCORED_ASSERTIONS` sets `inactive` every `affinity_to`
-- assertion whose concept the run did not score — the sweep that stops a claim
-- outliving its evidence — and a trip is scored by the travel writer rather than
-- by the concept loop, so its concept was absent from `scored_concepts` and it
-- was swept moments after it was written.
--
-- The symptom was quiet in the worst way: two assertions, two score versions,
-- two current scores, both `machine_state = inactive`, both invisible, and the
-- job reporting success. Nothing failed; the page simply had no travel in it.
--
-- The writer now returns the concepts it asserted and the caller adds them to
-- `scored_concepts`. This migration re-runs the scoring so the two trips come
-- back eligible.

begin;

do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.12.0: trips are exempt from the unscored sweep'
         ) into enqueued;
  raise notice '0160: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
