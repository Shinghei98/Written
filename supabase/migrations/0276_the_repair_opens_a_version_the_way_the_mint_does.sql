-- 0276 — the repair opens its version the way the mint opens one.
--
-- Fourth defect in one feature from the same cause. `0272`'s repair wrote
-- `insert into ontology.versions (version, status, notes) ... returning id`;
-- the real statement, in `0260:203`, is
-- `(id, version, parent_version_id, status, description)` selecting
-- `gen_random_uuid()` and the parent's id. So `id` is not defaulted, `notes`
-- was never a column, and `parent_version_id` — which `copy_forward_version`
-- and the version graph both depend on — was never set. Each was invisible
-- until the line ran: `0274` found the invented function, `0275` the invented
-- column, and this one the two remaining differences.
--
-- **The rule this feature has now paid for four times: patch a deployed body,
-- never retype one.** Recorded in `docs/PROJECT-CONTEXT.md` rather than left
-- as four migration headers nobody reads together.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.attach_kept_concept_parents(jsonb)'::regprocedure);

  patched := replace(body,
    E'insert into ontology.versions (version, status, description)\n'
    || E'  values (next_version, ''draft'', ''kept-term parents, derived from stated genre'')\n'
    || E'  returning id into new_version_id;',
    E'insert into ontology.versions (id, version, parent_version_id, status, description)\n'
    || E'  select gen_random_uuid(), next_version, v.id, ''draft'',\n'
    || E'         ''Kept-term parents, derived from the genre the source states.''\n'
    || E'    from ontology.versions v where v.version = current_version\n'
    || E'  on conflict (version) do nothing\n'
    || E'  returning id into new_version_id;');
  if patched = body then
    raise exception '0276: the repair does not open a version the way 0272 wrote it';
  end if;
  execute patched;
end;
$$;

do $$
declare
  body text;
begin
  body := pg_get_functiondef(
    'semantic_private.attach_kept_concept_parents(jsonb)'::regprocedure);
  if position('parent_version_id' in body) = 0 then
    raise exception '0276: the repair still opens a version with no parent';
  end if;
  if position('gen_random_uuid()' in body) = 0 then
    raise exception '0276: the repair still expects the id to default';
  end if;
  if (semantic_private.attach_kept_concept_parents('{}'::jsonb) ->> 'status')
       is distinct from 'no_op' then
    raise exception '0276: an empty repair did not decline';
  end if;
end;
$$;
