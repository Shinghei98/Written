-- 0155 — `0154` published an ontology version and did not enqueue the recompute.
--
-- **The rule is written down and this is the third migration to break it:**
-- *"A migration that publishes an ontology version or activates a model ends
-- with `semantic_private.enqueue_recompute_on_analysis_change`."* Ingestion is
-- the only other thing that enqueues, it fires only when a run changed
-- something, and it cannot see an ontology publish — so `0154` changed what the
-- system *would* compute and nothing it had.
--
-- The symptom is specific and was visible immediately: `list_assertions` reads
-- the block at `coalesce(score.ontology_version_id, …)`, the score's version
-- rather than the published one. So `0154`'s function change took effect at once
-- for terms whose parents already existed — Bach reached `genre:classical`
-- through an edge written long ago — while every edge `0154` itself authored was
-- invisible, because no score referenced 0.18.0. Kripparrian stayed in
-- "Games & play" and the science channels stayed on the undifferentiated shelf,
-- with the migration's own assertions passing, because those call
-- `concept_block` against the *published* version where the edges do exist.
--
-- Two readings of the same fact, and the one the page uses was the one nobody
-- checked.

begin;

do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.18.0: blocks are the finer parent (0154 omitted this)'
         ) into enqueued;
  raise notice '0155: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
