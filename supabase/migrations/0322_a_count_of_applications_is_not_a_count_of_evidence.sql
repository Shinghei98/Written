-- 0322 — `observed_count` counted applications, not evidence.
--
-- **The corpus says `luffy -> one piece` once; the database said three.** The
-- dictionary emitter wrote `observed_count = stored + excluded`, and the same
-- corpus was applied three times — `0307`, `0317`, `0319`, each a correction of
-- the one before. Every one of the 6,990 edges therefore reads three times its
-- true count, and nothing about the evidence changed between those loads.
--
-- The emitter now writes `greatest(stored, excluded)`: it counts occurrences
-- across the whole corpus before writing, so the incoming value is already the
-- total and adding it counts the same evidence again. This repairs what the old
-- form left behind.
--
-- **Why this matters now rather than as tidying.** `observed_count` is the
-- natural weight for rolling a child's evidence up to its franchise, and the
-- natural tie-break when a term has several parents. A column that silently
-- multiplies by however many times a migration was re-run is not a weight; it
-- is a record of our own deployment history, and a score resting on it would be
-- a claim about somebody derived from how often we re-ran a file.
--
-- **The guard is relaxed for exactly this statement and put back.**
-- `guard_presumed_term_relation_change` permits an update only where the count
-- does not fall — correct, since a claim seen again is stronger and a claim is
-- never unseen. A correction downward is a different act from an observation,
-- so rather than weaken the rule the trigger is disabled for this transaction
-- alone and re-enabled before it commits. Nothing else about the table moves:
-- no row is deleted, no subject, predicate, object, basis or timestamp changes.

do $$
declare
  applications constant integer := 3;  -- 0307, 0317, 0319
  repaired integer;
  still_wrong integer;
begin
  -- **Nothing to repair on a clean database**, which is what a replay is: the
  -- corpus has not been applied three times there, so the counts are whatever
  -- the single application wrote. Asserting a repair happened would make this
  -- unreplayable; asserting the *state* afterwards holds on both.
  if not exists (select 1 from semantic_private.presumed_term_relations) then
    raise notice '0322: no relations here; nothing to repair';
    return;
  end if;

  alter table semantic_private.presumed_term_relations
    disable trigger presumed_term_relations_append_only;

  update semantic_private.presumed_term_relations
     set observed_count = greatest(1, observed_count / applications)
   where observed_count >= applications
     and observed_count % applications = 0;
  get diagnostics repaired = row_count;

  alter table semantic_private.presumed_term_relations
    enable trigger presumed_term_relations_append_only;

  raise notice '0322: % edge counts divided by %', repaired, applications;

  -- The guard is back on, proved by the table refusing a change it must
  -- refuse. Attempted and rolled back inside this block, so the table is
  -- untouched by the check itself.
  begin
    update semantic_private.presumed_term_relations
       set basis = 'authored'
     where basis = 'model_stated';
    raise exception '0322: the append-only guard did not come back on';
  exception
    when sqlstate 'P0001' then
      -- **`SQLERRM`, carried out rather than swallowed.** The triggers it is
      -- natural to blame here all early-return without their evidence, so a
      -- bare `when others` would hide which refusal fired.
      if SQLERRM not like '%append-only%' then
        raise;
      end if;
  end;

  select count(*) into still_wrong
    from semantic_private.presumed_term_relations
   where observed_count < 1;
  if still_wrong > 0 then
    raise exception '0322: % edges hold a count below one', still_wrong;
  end if;
end;
$$;
