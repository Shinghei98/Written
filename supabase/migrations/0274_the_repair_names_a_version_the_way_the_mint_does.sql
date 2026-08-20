-- 0274 — the repair names its version the way the mint does.
--
-- `0272`'s repair called `semantic_private.next_ontology_version(...)`, a
-- function that has never existed — invented while restating a body rather
-- than reading it, which is the exact failure `0272`'s own header warns about
-- two paragraphs before committing it. Postgres does not resolve a call inside
-- a plpgsql body until the line runs, so it created cleanly and raised 42883
-- on the first repair, killing the job.
--
-- `0260` derives the next version inline — bump the patch component of the
-- published version — and this now does the same, by patching the deployed
-- body rather than retyping it a second time.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.attach_kept_concept_parents(jsonb)'::regprocedure);

  patched := replace(body,
    'next_version := semantic_private.next_ontology_version(current_version);',
    E'next_version := split_part(current_version, ''.'', 1) || ''.''\n'
    || E'                 || split_part(current_version, ''.'', 2) || ''.''\n'
    || E'                 || (split_part(current_version, ''.'', 3)::integer + 1)::text;');
  if patched = body then
    raise exception '0274: the repair does not call the function 0272 invented';
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
  if position('next_ontology_version' in body) > 0 then
    raise exception '0274: the repair still calls a function that does not exist';
  end if;
  if position('split_part(current_version' in body) = 0 then
    raise exception '0274: the repair does not derive its version';
  end if;

  -- **And it is exercised, not merely rewritten.** An empty argument returns
  -- the no-op branch without opening a version, which is the same answer on a
  -- replay database and in production once nothing floats.
  if (semantic_private.attach_kept_concept_parents('{}'::jsonb) ->> 'status')
       is distinct from 'no_op' then
    raise exception '0274: an empty repair did not decline';
  end if;
end;
$$;
