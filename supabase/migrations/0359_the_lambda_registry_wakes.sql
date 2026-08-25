-- 0359 — the λ registry wakes: weight propagates, by authored fraction.
--
-- **The owner's directive, 2026-08-25, superseding the scorer's zero-hop
-- commitment.** Direct evidence keeps full weight; every term connected to
-- it, directly or transitively through predicate edges, receives a decaying
-- fraction — the per-predicate λ that 0291 authored and nothing ever read
-- (GRAMMARBOOK Part 4 §4 records the dormancy), multiplied per hop, cut off
-- at a negligibility floor rather than a hop cap. The worked example is the
-- calibration: a play of "My Heart Will Go On" carries the song and its
-- performer at full weight, `work:titanic` at soundtrack_of's 0.25, and the
-- film's genre at 0.25 × broader's 0.40 = 0.10 — the owner's +1 / +0.2 /
-- +0.1, reproduced from the registry rather than hardcoded.
--
-- **What this migration itself does is small and versioned:**
--
-- 1. `broader` enters the registry. 0291 promised λ_parent and never stored
--    it; the scorer's walk needs a λ for the parent edge like any other.
--    0.40, `registry_version = 'predicate-v2.1'` on every row this touches.
-- 2. Scorer 0.18.0 (λ propagation; derived concepts scored, asserted mostly
--    `candidate`, evidence rows naming the source mapping through a stated
--    path) and resolver 0.14.0 (a non-classical composer credit at 0.6 —
--    the owner: "to a lesser degree since it's a non-classical song")
--    activate; predecessors retire by role. Deployed with the code, never
--    ahead of it.
--
-- The inferred tail this creates exists to expand the global vocabulary and
-- to be judged: most of it lands below every bar, visible only under a
-- Memories cutoff release that admits it (0360). Nothing here touches
-- machine_state semantics, the revision, or any append-only table.

begin;

-- ---------------------------------------------------------------------
-- 1. broader joins the registry; touched rows carry the new version.
-- ---------------------------------------------------------------------
-- Production necessarily holds the row — every broader edge references it —
-- so the insert is the clean-replay path and the update is the change.
insert into ontology.relation_types (
  predicate_key, relation_class, assertion_safe, description,
  propagation_weight, reverse_propagation_weight,
  minimum_propagation_authority, minimum_relation_confidence,
  may_propagate_user_predicates, registry_version
)
select 'broader', 'hierarchical', false,
       'The child names the parent: a work its genre, a genre its medium.',
       0.40, 0.0, 'supported', 0.65,
       array['affinity_to'], 'predicate-v2.1'
where not exists (
  select 1 from ontology.relation_types where predicate_key = 'broader');

update ontology.relation_types
   set propagation_weight = 0.40,
       registry_version = 'predicate-v2.1'
 where predicate_key = 'broader'
   and (propagation_weight is distinct from 0.40
        or registry_version is distinct from 'predicate-v2.1');

do $$
declare
  lam numeric;
begin
  select propagation_weight into lam
    from ontology.relation_types where predicate_key = 'broader';
  if lam is distinct from 0.40 then
    raise exception '0359: broader carries λ %, expected 0.40', lam;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. The model versions move with the code.
-- ---------------------------------------------------------------------
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.18.0'),
  'evidence_weighted_scorer', '0.18.0', 'scorer', null,
  '{"lambda_propagation": "raw pre-saturation weight walks every active'
  ' curated/provider concept edge whose predicate carries propagation_weight'
  ' > 0 and whose own confidence clears minimum_relation_confidence;'
  ' per-source path weight is the max over paths of the per-edge lambda'
  ' product; contributions sum across sources; targets holding any direct'
  ' mapping in the run receive nothing",'
  ' "propagation_floor": 0.05,'
  ' "derived_confidence": "saturating count of distinct contributing source'
  ' concepts, half at 4; breadth 1",'
  ' "derived_assertions": "candidate below the unchanged bars, with'
  ' assertion rows so the Memories page can carry the tail",'
  ' "supersedes": "the zero-hop commitment recorded in score.py, owner'
  ' directive 2026-08-25"}'::jsonb,
  'active'
) on conflict (id) do nothing;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.14.0'),
  'ontology_first_resolver', '0.14.0', 'resolver', null,
  '{"nonclassical_composer_weight": 0.6,'
  ' "rationale": "a stated composer credit on a non-classical song is a read'
  ' and counts, to a lesser degree (owner, 2026-08-25); classical composers'
  ' keep full weight because there the composer is the taste"}'::jsonb,
  'active'
) on conflict (id) do nothing;

-- Retired by role, not by name (0161's replay lesson).
update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and status = 'active' and version <> '0.18.0';
update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and status = 'active' and version <> '0.14.0';

do $$
declare
  active_scorers integer;
  active_resolvers integer;
  enqueued integer;
begin
  select count(*) into active_scorers
    from ontology.model_versions where model_role = 'scorer' and status = 'active';
  select count(*) into active_resolvers
    from ontology.model_versions where model_role = 'resolver' and status = 'active';
  if active_scorers <> 1 or active_resolvers <> 1 then
    raise exception '0359: expected one active scorer and one active resolver, found % and %',
      active_scorers, active_resolvers;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.18.0 / resolver 0.14.0: lambda propagation and the '
           'non-classical composer weight'
         ) into enqueued;
  raise notice '0359: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
