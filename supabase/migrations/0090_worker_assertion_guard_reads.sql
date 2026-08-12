-- 0090 — every table the assertion guards read, in one migration.
--
-- **Five migrations found five grants by watching five invocations fail.**
-- `0063`, `0070`–`0073`, `0086`, `0087`, `0088`, `0089` — each one the next
-- refusal in a chain, each costing a deploy and a run to discover a fact that
-- was static the whole time. `0088` said a further round would mean the reading
-- was incomplete; it was, twice.
--
-- So this set comes from the catalog rather than from another failure: the
-- trigger functions on the four tables the scorer writes, plus the helpers they
-- call, searched for every `semantic_private` table they name that the worker
-- cannot read. Six, and they are all reads.
--
--   `healthkit_derived_assertions`  what a HealthKit-derived claim rests on
--   `fitness_habit_candidates`      and whether that candidate still stands
--   `fitness_candidate_support`     which raw rows support it
--   `fitness_candidate_observations` and which observations do
--   `assertion_preferences`         what the user has said about this claim
--   `motif_instances`               whether a score came from a motif
--
-- **All select, and the pattern is worth naming.** Every one answers *may this
-- claim exist and does it still hold* — `guard_assertion_evidence_writable`,
-- `reject_stale_inferred_assertion`, `guard_motif_score_output`. A scorer must
-- be able to ask all of them and change none of them, which is why not one
-- write appears below.
--
-- `assertion_preferences` is the sharpest of the six: it holds what somebody has
-- said about a claim of their own. Read so a stale inferred assertion can be
-- refused; never written, because a scorer that could edit a preference could
-- overwrite a person's own answer with a computed one.

begin;

grant select on semantic_private.healthkit_derived_assertions to semantic_worker;
grant select on semantic_private.fitness_habit_candidates to semantic_worker;
grant select on semantic_private.fitness_candidate_support to semantic_worker;
grant select on semantic_private.fitness_candidate_observations to semantic_worker;
grant select on semantic_private.assertion_preferences to semantic_worker;
grant select on semantic_private.motif_instances to semantic_worker;

do $$
declare
  needed text[] := array[
    'healthkit_derived_assertions', 'fitness_habit_candidates',
    'fitness_candidate_support', 'fitness_candidate_observations',
    'assertion_preferences', 'motif_instances'
  ];
  name text;
begin
  foreach name in array needed loop
    if not pg_catalog.has_table_privilege(
         'semantic_worker', 'semantic_private.'||name, 'select') then
      raise exception 'semantic_worker still cannot read %', name;
    end if;
    -- Read-only, asserted per table rather than once: a later migration adding
    -- a write to any of these would be widening the scorer into a writer of
    -- other subsystems' state, and it should fail here when it does.
    if pg_catalog.has_table_privilege(
         'semantic_worker', 'semantic_private.'||name, 'insert')
       or pg_catalog.has_table_privilege(
         'semantic_worker', 'semantic_private.'||name, 'update')
       or pg_catalog.has_table_privilege(
         'semantic_worker', 'semantic_private.'||name, 'delete') then
      raise exception 'semantic_worker must only read %', name;
    end if;
  end loop;
end
$$;

commit;
