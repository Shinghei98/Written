-- 0374 — stated relations earn their edges, N-supported and kind-agreed.
--
-- **The disambiguation ladder's prerequisite (owner's design, 2026-08-25).**
-- Tier 2 — "a candidate whose catalogue relations reach any resolved term
-- in the entry wins, binding" — needs catalogue relations, and the
-- catalogue holds four. The 12,000 model-stated relations live in
-- `presumed_term_relations` (0306), whose header rightly said *nothing
-- reads this table into the ontology* — a model's sentence is a proposal,
-- not an edge. This is the governed lane that ends the dormancy the way
-- parent minting ended the proposal queue's (0341): a relation crosses
-- only when
--
--   * **both ends are promoted concepts** — identity first, relation second;
--   * **support >= 2** summed observed occurrences — one sighting proposes,
--     two begin to agree (the N-floor the mint gates use, scaled to a
--     corpus of one library);
--   * **the predicate is registered** in `ontology.relation_types`;
--   * **the ends' kinds agree with the predicate** — performed_by is
--     work-to-creator, member_of_group creator-to-creator, composed_by
--     work-to-creator, part_of_franchise work-or-creator-to-work,
--     soundtrack_of work-to-work, recording_of work-to-work — a pair that
--     disagrees is refused and counted, never bent.
--
-- Edges land `learned` — a model's corroborated statement, honestly
-- labelled, outside λ propagation's curated/provider wall until decided
-- otherwise. λ traversal is untouched; what these edges feed is the
-- ladder's tier-2 join and the anchor machinery.
--
-- Replayable by asserting the transformation: a clean database holds no
-- promoted dictionary terms, promotes nothing, and that is correct there.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  eligible        integer;
  written         integer := 0;
  kind_refused    integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _relations on commit drop as
  select s.promoted_concept_id as subject_id,
         r.predicate,
         o.promoted_concept_id as object_id,
         sum(r.observed_count) as support
    from semantic_private.presumed_term_relations r
    join semantic_private.presumed_terms s
      on s.id = r.subject_term_id and s.promoted_concept_id is not null
    join semantic_private.presumed_terms o
      on o.id = r.object_term_id and o.promoted_concept_id is not null
   where exists (select 1 from ontology.relation_types t
                  where t.predicate_key = r.predicate)
     and s.promoted_concept_id <> o.promoted_concept_id
   group by 1, 2, 3
  having sum(r.observed_count) >= 2;

  select count(*) into eligible from _relations;
  if eligible = 0 then
    raise notice '0374: no relation clears the gates here; nothing promotes';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'N-supported, kind-agreed stated relations become learned edges.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The kind agreement, judged at the new version off each end's revision.
  create temporary table _judged on commit drop as
  select rel.*, sk.concept_kind as s_kind, ok.concept_kind as o_kind,
         case rel.predicate
           when 'performed_by'      then sk.concept_kind = 'work'    and ok.concept_kind = 'creator'
           when 'composed_by'       then sk.concept_kind = 'work'    and ok.concept_kind = 'creator'
           when 'member_of_group'   then sk.concept_kind = 'creator' and ok.concept_kind = 'creator'
           when 'part_of_franchise' then sk.concept_kind in ('work', 'creator') and ok.concept_kind = 'work'
           when 'soundtrack_of'     then sk.concept_kind = 'work'    and ok.concept_kind = 'work'
           when 'recording_of'      then sk.concept_kind = 'work'    and ok.concept_kind = 'work'
           when 'located_in'        then ok.concept_kind in ('place', 'culture')
           else false
         end as congruent
    from _relations rel
    join ontology.concept_revisions sk
      on sk.concept_id = rel.subject_id
     and sk.ontology_version_id = new_version_id and sk.status = 'active'
    join ontology.concept_revisions ok
      on ok.concept_id = rel.object_id
     and ok.ontology_version_id = new_version_id and ok.status = 'active';

  select count(*) into kind_refused from _judged where not congruent;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, j.subject_id, j.predicate, j.object_id,
         least(0.9, 0.5 + 0.1 * j.support), 'learned',
         jsonb_build_object('source', '0374_relation_promotion',
                            'support', j.support), 'active'
    from _judged j
   where j.congruent
  on conflict do nothing;
  get diagnostics written = row_count;

  if written = 0 then
    raise exception '0374: eligible relations existed and none crossed';
  end if;

  -- No written edge may disagree with its predicate's kind contract.
  if exists (
    select 1 from ontology.concept_edges e
    join _judged j on j.subject_id = e.subject_concept_id
                  and j.object_id = e.object_concept_id
                  and j.predicate = e.predicate_key
    where e.ontology_version_id = new_version_id
      and coalesce(e.provenance->>'source','') = '0374_relation_promotion'
      and not j.congruent) then
    raise exception '0374: an incongruent relation crossed';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || written || ' stated relation(s) promoted');
  raise notice '0374: % published — % edge(s) promoted of % eligible, % refused on kind',
    next_version, written, eligible, kind_refused;
end;
$$;

commit;
