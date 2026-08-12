-- 0089 — the evidence guards, found by asking the catalog instead of the logs.
--
-- **`0088` said a fifth round would mean the reading was incomplete, and it
-- was.** It granted the two functions `guard_youtube_assertion_evidence` calls
-- and missed `guard_calendar_assertion_evidence` beside it, which calls
-- `assertion_has_calendar_evidence` — so the next invocation failed on exactly
-- the sibling of the thing just fixed.
--
-- This time the set comes from the catalog rather than from reading migration
-- text: every `semantic_private` function taking arguments that the worker
-- cannot execute and that an evidence or assertion guard could reach. Trigger
-- functions themselves are excluded on purpose — Postgres runs a trigger
-- regardless of the invoker's execute privilege, so granting those would be
-- noise that looks like security.
--
-- **Every one is a read that answers a question about eligibility**, and the
-- pattern across them is the same: *is this still current, and may it be shown*.
-- `assertion_has_calendar_evidence` and `assertion_has_healthkit_evidence` ask
-- what a claim rests on; `healthkit_assertion_is_current` and
-- `fitness_candidate_is_current` ask whether the thing it rested on still
-- holds. A scorer must be able to ask all of them and change none.

begin;

grant execute on function
  semantic_private.assertion_has_calendar_evidence(uuid, uuid) to semantic_worker;
grant execute on function
  semantic_private.assertion_has_healthkit_evidence(uuid, uuid) to semantic_worker;
grant execute on function
  semantic_private.healthkit_assertion_is_current(uuid, uuid) to semantic_worker;
grant execute on function
  semantic_private.fitness_candidate_is_current(uuid, uuid) to semantic_worker;
grant execute on function
  semantic_private.scheduled_travel_candidate_is_current_v03(uuid, uuid) to semantic_worker;

do $$
declare
  granted text[] := array[
    'semantic_private.assertion_has_calendar_evidence(uuid, uuid)',
    'semantic_private.assertion_has_healthkit_evidence(uuid, uuid)',
    'semantic_private.healthkit_assertion_is_current(uuid, uuid)',
    'semantic_private.fitness_candidate_is_current(uuid, uuid)',
    'semantic_private.scheduled_travel_candidate_is_current_v03(uuid, uuid)'
  ];
  signature text;
begin
  -- **Named one by one rather than matched by pattern.** The first draft
  -- asserted that *no* `%_is_current` function was still denied, which swept in
  -- `dyad_run_is_current` and `validated_surface_fact_is_current` — Phase 4's
  -- dyad and surface paths, which this migration deliberately does not touch.
  -- The assertion failed and the migration rolled back, correctly: a check
  -- broad enough to demand privileges nobody asked for would have been an
  -- argument for granting them.
  foreach signature in array granted loop
    if not pg_catalog.has_function_privilege('semantic_worker', signature, 'execute') then
      raise exception 'semantic_worker still cannot evaluate %', signature;
    end if;
  end loop;

  -- **The surface and dyad paths stay shut**, and that is the half worth
  -- asserting: they matched the same catalog query by naming coincidence, and
  -- granting on a coincidence is how a privilege set stops meaning anything.
  if pg_catalog.has_function_privilege(
       'semantic_worker', 'semantic_private.assert_surface_allowed(text)', 'execute')
     or pg_catalog.has_function_privilege(
       'semantic_worker', 'semantic_private.validated_surface_fact_is_current(uuid)',
       'execute') then
    raise exception 'the worker has been given a surface-path privilege it does not need';
  end if;
end
$$;

commit;
