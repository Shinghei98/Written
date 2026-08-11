-- 0073 — a CHECK constraint calls a function, and that needs execute too.
--
-- `observation_mappings_recency_v02_check` is
-- `check (semantic_private.recency_audit_is_valid(...))`, and a check constraint
-- evaluates as the *inserting* role. So the worker could reach the table, pass
-- every trigger, and still be refused with `permission denied for function
-- recency_audit_is_valid`.
--
-- **The whole list, verified from the catalog rather than by another round of
-- being refused.** Only one check constraint on `observation_mappings`,
-- `semantic_runs` or `youtube_run_policies` calls a `semantic_private` function,
-- and this is it. The trigger-driven grants (`0069`-`0072`) had to be found by
-- running; this one could be enumerated, so it was.
--
-- Execute on a pure validator: it takes six scalars and returns a boolean, reads
-- nothing and writes nothing.

begin;

grant execute on function semantic_private.recency_audit_is_valid(
  double precision, double precision, text, text, text, text
) to semantic_worker;

do $$
declare
  missing text;
begin
  select string_agg(signature, ', ')
    into missing
  from (values
    ('semantic_private.observation_is_current_v031(uuid,uuid)'),
    ('semantic_private.recency_audit_is_valid(double precision,double precision,text,text,text,text)')
  ) as required(signature)
  where not pg_catalog.has_function_privilege('semantic_worker', signature, 'execute');

  if missing is not null then
    raise exception 'semantic_worker cannot call: %', missing;
  end if;
end
$$;

commit;
