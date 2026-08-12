-- 0097 — the recompute `0095` and `0096` owed.
--
-- **`0093` wrote the rule and the next two migrations broke it.** Its own
-- comment: *"Any future migration publishing an ontology version or activating a
-- model should end with this call for the same reason."* `0095` published
-- 0.8.0 and `0096` published 0.9.0, and neither did — so 35 new concepts, a new
-- composer-period vocabulary and a scorer that withholds bare eras all sat in
-- the database describing what the system *would* compute, with nothing
-- computed. Exactly the state `0092`/`0093` were written to escape, re-entered
-- within the hour by the person who wrote them.
--
-- It is a separate migration only because the two that owed it have already
-- applied. The call is idempotent — the key carries the ontology version and
-- the model ids — so this enqueues one job per user whose current revision has
-- no run against 0.9.0, and nothing on a replay.
--
-- **A migration is the only caller that can.** `0093` revokes execute from
-- `public`, so the function runs as the owner and `db push` is the owner's
-- session. That is deliberate: enqueuing work for every user is not something
-- a client role should be able to do.

begin;

do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    'ontology 0.9.0: language spheres, decade-sphere scenes, composer periods'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for ontology 0.9.0', enqueued;
end
$$;

commit;
