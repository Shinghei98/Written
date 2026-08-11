-- 0072 — the mapping guard calls a function, and privileges are not only tables.
--
-- `guard_mapping_current_source_v031` refuses a candidate or accepted mapping
-- unless `semantic_private.observation_is_current_v031` says the item is still
-- present. That function's execute privilege was revoked from `public` along
-- with everything else in this schema, so the worker could open a run and then
-- fail on the first mapping with `permission denied for function
-- observation_is_current_v031`.
--
-- **Four grants in a row, each found by being refused.** `versions`,
-- `embedding_models`, `youtube_run_policies` (insert *and* select), and now an
-- execute. That is what `security invoker` triggers cost: their reads are
-- invisible at the call site, so the only way to enumerate them is to run the
-- statement and read what it asks for. Worth recording rather than tidying away
-- — the next stage that writes into this schema will meet the same thing.
--
-- Execute only. The function is a read: it answers whether one observation's
-- item is currently present, which the worker is already allowed to determine
-- for itself from `current_source_items`.

begin;

grant execute on function semantic_private.observation_is_current_v031(uuid, uuid)
  to semantic_worker;

do $$
begin
  if not pg_catalog.has_function_privilege(
       'semantic_worker',
       'semantic_private.observation_is_current_v031(uuid,uuid)',
       'execute') then
    raise exception 'semantic_worker cannot call observation_is_current_v031';
  end if;
  -- The worker reads current state and must never write it: a mapping is
  -- evidence about an item, not a claim that the item exists.
  if pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.current_source_items', 'insert')
     or pg_catalog.has_table_privilege(
       'semantic_worker', 'semantic_private.current_source_items', 'update') then
    raise exception 'semantic_worker can write current state';
  end if;
end
$$;

commit;
