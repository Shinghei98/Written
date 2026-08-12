-- 0088 — what writing an assertion actually touches.
--
-- `0079` granted the four tables the scorer writes and stopped there, because
-- that is what the scorer's own SQL names. It is not what an insert *does*:
-- `user_assertions` carries `initialize_assertion_surface_permissions`, which
-- writes a permissions row for the new assertion, and `assertion_evidence`
-- carries `guard_youtube_assertion_evidence`, which asks two functions whether
-- YouTube-derived evidence may reach a surface. Triggers are `security
-- invoker`, so all of it runs as the worker.
--
-- **Granted together rather than one refusal at a time.** The previous four
-- grant migrations each came from watching a single invocation fail, which is a
-- slow way to discover a static fact. These were found by reading `pg_trigger`
-- for the tables the scorer writes and following what each trigger calls — so
-- this migration is the whole set, and a fifth round would mean the reading was
-- incomplete rather than that another grant merely surfaced.
--
-- **Surface permissions are initialised, never widened.** The trigger writes the
-- row; nothing here lets the worker update or delete one. What an assertion may
-- appear on is a decision recorded elsewhere, and a scorer that could edit it
-- could publish a claim to a surface nobody authorised.

begin;

grant select, insert on semantic_private.assertion_surface_permissions
  to semantic_worker;

grant execute on function semantic_private.assertion_has_youtube_evidence(uuid, uuid)
  to semantic_worker;
grant execute on function semantic_private.youtube_assertion_gate_allowed(uuid, uuid, text)
  to semantic_worker;

do $$
begin
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_surface_permissions', 'insert') then
    raise exception 'the assertion trigger cannot initialise its permissions row';
  end if;
  if not pg_catalog.has_function_privilege(
       'semantic_worker',
       'semantic_private.assertion_has_youtube_evidence(uuid, uuid)', 'execute')
     or not pg_catalog.has_function_privilege(
       'semantic_worker',
       'semantic_private.youtube_assertion_gate_allowed(uuid, uuid, text)', 'execute') then
    raise exception 'the YouTube evidence guard cannot be evaluated';
  end if;

  -- **Initialising is not widening.** The trigger creates the row; the worker
  -- must never be able to change what a claim may be shown on.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_surface_permissions', 'update')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_surface_permissions', 'delete') then
    raise exception 'semantic_worker must not be able to widen a surface permission';
  end if;

  -- Still true from `0079`, re-asserted because this is a grant migration and
  -- that is exactly where it could be lost: promotion stays a transition
  -- performed by `finalize_semantic_run`, not a table the worker can write.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.assertion_current_scores', 'insert') then
    raise exception 'semantic_worker must not write assertion_current_scores directly';
  end if;
end
$$;

commit;
