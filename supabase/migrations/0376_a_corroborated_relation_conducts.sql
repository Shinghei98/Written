-- 0376 — scorer 0.19.0: a corroborated relation conducts weight.
--
-- **The owner's franchise rule, 2026-08-25: "when our system sees a work,
-- it must first think: is there a franchise? Registered → use it; clear
-- and absent → mint it. Iron Man and Thor both predicate on
-- franchise:MCU and trickle weight to it concurrently."**
--
-- The trickle half needed one wall opened: λ propagation traversed only
-- curated/provider edges, so the 0374 lane's promoted relations — the
-- very edges the franchise rule produces — conducted nothing. Scorer
-- 0.19.0 admits them, and only them: an edge is `learned` *and* stamped
-- `0374_relation_promotion`, meaning it already passed both-ends-promoted,
-- support >= 2, a registered predicate and per-predicate kind agreement.
-- A bare model statement still conducts nothing; corroboration is the
-- price of current.
--
-- The register-or-mint half is the corpus lane's (franchise-first at work
-- registration, GRAMMARBOOK §2.19) and changes no schema here. The MCU of
-- the owner's example is correctly *not* minted today: one supporting
-- relation, below every floor — the rule builds it the day the evidence
-- does.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.19.0'),
  'evidence_weighted_scorer', '0.19.0', 'scorer', null,
  '{"propagation_edge_admission": "curated, provider, and learned edges'
  ' stamped 0374_relation_promotion — corroborated promotions conduct;'
  ' bare model statements do not",'
  ' "rationale": "the owner''s franchise rule: sibling works trickle'
  ' weight to their franchise concurrently through part_of_franchise'
  ' (lambda 0.45), which requires the promoted relation lane to carry'
  ' current"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and status = 'active' and version <> '0.19.0';

do $$
declare
  actives integer;
  enqueued integer;
begin
  select count(*) into actives
    from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if actives <> 1 then
    raise exception '0376: expected exactly one active scorer, found %', actives;
  end if;
  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.19.0: corroborated relations conduct weight'
         ) into enqueued;
  raise notice '0376: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
