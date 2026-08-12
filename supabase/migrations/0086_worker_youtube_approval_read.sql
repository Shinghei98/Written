-- 0086 — the worker cannot open a run it is allowed to open.
--
-- **`0078` gave `initialize_youtube_run_policy` something to read, and did not
-- give the reader permission.** Before it, the trigger inserted a row of
-- defaults and touched nothing else; now it consults
-- `ontology.youtube_policy_approvals` and `ontology.model_versions` to decide
-- what the run may do. It carries no `security definer`, so it runs as whoever
-- inserted the `semantic_runs` row — the worker — and the worker holds select on
-- `model_versions` and not on the approvals table.
--
-- Every `recompute_user` job therefore failed with
--
--     42501: permission denied for table youtube_policy_approvals
--
-- surfacing as the queue's stable `handler_error`, which by design carries no
-- detail. Six jobs sat queued behind it with 575 YouTube observations already
-- captured and nothing to resolve them. The fifth worker grant this project has
-- found by watching something be refused, after `0063` and `0070`–`0073`.
--
-- **Select only, and the alternative was worse.** Making the trigger
-- `security definer` would have worked too and would have handed a run-creating
-- path the owner's rights for the sake of one lookup; a read grant on a table
-- of approval references and booleans is the smaller thing to give. Nothing in
-- it is user data, and the worker still cannot write it — an approval remains
-- something a person records by hand, which is the whole point of `0078`.

begin;

grant select on ontology.youtube_policy_approvals to semantic_worker;

do $$
begin
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.youtube_policy_approvals', 'select') then
    raise exception 'semantic_worker still cannot read the YouTube approvals';
  end if;

  -- **The negative half, and it is the one that matters.** The worker must
  -- never be able to grant itself a permission: an approval is a recorded
  -- decision, and a process that could write one could license channel
  -- identity, title tagging or a surface for itself.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.youtube_policy_approvals', 'insert')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.youtube_policy_approvals', 'update')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.youtube_policy_approvals', 'delete') then
    raise exception 'semantic_worker must not be able to record an approval';
  end if;

  -- The other table the same trigger reads, asserted here so a future change to
  -- one of them fails at migration time rather than at the next distillation.
  if not pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.model_versions', 'select') then
    raise exception 'semantic_worker cannot read the resolver model version';
  end if;
end
$$;

commit;
