-- 0087 — the gate that decides an uploader tag cannot be asked.
--
-- `guard_youtube_mapping_fusion` maps each `youtube_semantic_kind` to the
-- permission it needs and asks `youtube_run_gate_allowed` whether this run has
-- it. `provider_topic` maps to `null` and skips the call entirely — which is why
-- topic mappings would have worked without this — but `uploader_tag` maps to
-- `uploader_tags`, so every tag mapping died on
--
--     42501: permission denied for function youtube_run_gate_allowed
--
-- The sixth grant found by watching something be refused, and the second inside
-- one job. `0086` unblocked reading the approval; this unblocks asking what the
-- approval permits.
--
-- **Execute is the whole grant, and that is the point of the function.** It
-- reads `youtube_run_policies` for one run and answers a boolean. The worker
-- gains no way to see another user's policy, no way to change one, and no way
-- to record an approval — `0086` asserts that last one and this migration
-- re-asserts it, because a grant migration is exactly where it could be lost.

begin;

grant execute on function semantic_private.youtube_run_gate_allowed(uuid, text)
  to semantic_worker;

do $$
begin
  if not pg_catalog.has_function_privilege(
       'semantic_worker',
       'semantic_private.youtube_run_gate_allowed(uuid, text)', 'execute') then
    raise exception 'semantic_worker cannot ask whether a YouTube gate is open';
  end if;

  -- Asking is not granting. The worker must still be unable to open a gate for
  -- itself, either by recording an approval or by editing a run's policy.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.youtube_policy_approvals', 'insert')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'ontology.youtube_policy_approvals', 'update') then
    raise exception 'semantic_worker must not be able to record an approval';
  end if;
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.youtube_run_policies', 'update')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.youtube_run_policies', 'delete') then
    raise exception 'semantic_worker must not be able to widen a run policy';
  end if;
end
$$;

commit;
