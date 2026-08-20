-- 0275 — the repair names the column the table has.
--
-- `ontology.versions` has `description`; `0272`'s repair wrote `notes`. Third
-- defect in one feature from restating a body instead of reading it, after the
-- invented `next_ontology_version` (`0274`) and the two clauses the first draft
-- of `0272` silently changed. The lesson is already written in `0272`'s own
-- header and was not enough: **patch a deployed body, never retype one.**

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.attach_kept_concept_parents(jsonb)'::regprocedure);
  patched := replace(body,
    E'insert into ontology.versions (version, status, notes)',
    E'insert into ontology.versions (version, status, description)');
  if patched = body then
    raise exception '0275: the repair does not name the column 0272 invented';
  end if;
  execute patched;
end;
$$;

do $$
begin
  if position('status, notes)' in
              pg_get_functiondef(
                'semantic_private.attach_kept_concept_parents(jsonb)'::regprocedure)) > 0 then
    raise exception '0275: the repair still names a column the table does not have';
  end if;
  if (semantic_private.attach_kept_concept_parents('{}'::jsonb) ->> 'status')
       is distinct from 'no_op' then
    raise exception '0275: an empty repair did not decline';
  end if;
end;
$$;
