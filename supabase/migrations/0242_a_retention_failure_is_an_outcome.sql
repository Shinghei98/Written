-- 0242 — a retention failure is an outcome, and it withholds the result.
--
-- `0236` closed the operational vocabulary at fourteen and its own assertion
-- says a fifteenth added without thought fails there. This is the deliberate
-- fifteenth.
--
-- ## What it names
--
-- SageMaker asynchronous inference hands the answer back as an S3 object, so a
-- successful extraction leaves a file containing text derived from somebody's
-- title. The transport deletes it as it reads it — before parsing, so a
-- malformed body cannot be the reason a file survives.
--
-- **If that delete fails, the call has not succeeded.** The model answered, the
-- mentions are valid, and we cannot show that the copy is gone. The first
-- version swallowed the failure on the reasoning that a delete which raised
-- would turn a successful extraction into a failure. That is exactly what it
-- should do: the alternative is committing semantics derived from text we
-- cannot prove we stopped holding, and the one-day lifecycle rule is a backstop
-- for a process that died, not a licence to proceed past a refusal.
--
-- So `retention_failed` is an outcome like the rest, `mention_count` is zero on
-- it by the constraint `0236` already carries, and no mention may descend from
-- it because `0237` admits only `succeeded`.
--
-- The vocabulary is closed and stays closed: this is an addition argued for,
-- not a widening.

alter table semantic_private.model_invocation_items
  drop constraint if exists model_invocation_items_outcome_check;

alter table semantic_private.model_invocation_items
  add constraint model_invocation_items_outcome_check
  check (outcome in (
    'succeeded',
    'semantic_abstention',
    'input_oversize',
    'output_overflow',
    'schema_invalid',
    'offset_invalid',
    'missing_item',
    'duplicate_item',
    'source_stale',
    'timeout',
    'rate_limited',
    'provider_error',
    'contract_mismatch',
    'circuit_open',
    -- The output object could not be deleted. The model answered and the result
    -- is withheld, because we cannot show the copy is gone.
    'retention_failed'));

do $$
declare
  n integer;
begin
  -- Read back from the catalog: a constraint that exists only in this file is a
  -- claim about a database rather than a property of one.
  select count(*) into n
    from pg_constraint c
    join pg_class r on r.oid = c.conrelid
    join pg_namespace ns on ns.oid = r.relnamespace
   where ns.nspname = 'semantic_private'
     and r.relname = 'model_invocation_items'
     and c.conname = 'model_invocation_items_outcome_check'
     and pg_get_constraintdef(c.oid) like '%retention_failed%'
     and pg_get_constraintdef(c.oid) like '%semantic_abstention%'
     and pg_get_constraintdef(c.oid) like '%circuit_open%';
  if n <> 1 then
    raise exception '0242: the outcome vocabulary did not gain retention_failed';
  end if;

  -- And it carries no mentions, which `0236`'s constraint already decides —
  -- asserted here because the whole point of this outcome is that nothing
  -- downstream of it may exist.
  begin
    insert into semantic_private.model_invocation_items
      (invocation_id, item_index, logical_extraction_key, outcome, mention_count)
    values (extensions.gen_random_uuid(), 0, 'probe', 'retention_failed', 1);
    raise exception '0242: a retention failure carried mentions';
  exception
    when check_violation then null;
    when foreign_key_violation then null;
  end;
end;
$$;
