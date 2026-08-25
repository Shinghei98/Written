-- 0380 — scorer 0.20.0: a declared claim below the bar still gets its
--          measurement.
--
-- **Found chasing the owner's weight-bar question (2026-08-25).** The
-- concept loop's below-bar path demoted-and-continued *before* the score
-- write, so a kept or typed assertion whose concept fell under the bar
-- never received a score version — measured on a real account: a kept
-- creator at strength 0.231 with nine mappings and zero score versions,
-- drawing bar-less forever. The bar governs what the *machine* asserts;
-- a person's own claim is shown by declaration, and withholding its
-- measurement conflated the two — the same conflation the identity/weight
-- correction (0377) removed from minting, one layer down.
--
-- Scorer 0.20.0: below the bar, if a non-inferred assertion stands for
-- the concept under the predicate the evidence chose, the score version
-- writes against it — machine_state untouched, DEMOTE still inferred-only.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.20.0'),
  'evidence_weighted_scorer', '0.20.0', 'scorer', null,
  '{"declared_scored_below_bar": "a standing non-inferred assertion'
  ' receives its concept''s score version even when strength falls below'
  ' the eligibility bar — the bar governs machine claims, never the'
  ' measurement of a person''s own"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and status = 'active' and version <> '0.20.0';

do $$
declare
  actives integer;
  enqueued integer;
begin
  select count(*) into actives
    from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if actives <> 1 then
    raise exception '0380: expected exactly one active scorer, found %', actives;
  end if;
  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.20.0: declared claims measured below the bar'
         ) into enqueued;
  raise notice '0380: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
