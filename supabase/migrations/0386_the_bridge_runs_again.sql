-- 0386 — the bridge runs again: a per-cycle act, not a one-shot.
--
-- **The v20 placements (369 rows, corpus ris_v20) landed in the dictionary
-- and the page still read the old edges** — 0369's bridge ran once, before
-- they existed, and a bridge that must be re-run each corpus cycle is a
-- fact this file now records: the emit pipeline's deploy tail includes a
-- bridge migration per cycle until the bridge becomes a function. Body is
-- 0369's verbatim (same gates: promoted-only, no-edge-or-0272-only,
-- authored never overwritten, hub parents refused since 0375's correction
-- — carried here explicitly, congruence per subtype), re-keyed 0386.
--
begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  candidates      integer;
  bridged         integer := 0;
  rejected_0272   integer := 0;
  refused         integer := 0;
  refused_names   text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- Every (concept, parent) the dictionary proposes: the primary and the
  -- per-hub placements, deduplicated.
  create temporary table _bridge on commit drop as
  with proposals as (
    select t.promoted_concept_id as concept_id, t.family, t.person_subtype,
           t.proposed_parent_concept_id as parent_id,
           coalesce(t.proposed_parent_confidence_unvalidated, 0.8) as confidence
      from semantic_private.presumed_terms t
     where t.promoted_concept_id is not null
       and t.proposed_parent_concept_id is not null
    union
    select t.promoted_concept_id, t.family, t.person_subtype,
           p.parent_concept_id, coalesce(p.confidence, 0.8)
      from semantic_private.presumed_terms t
      join semantic_private.presumed_term_placements p
        on p.normalized_label = t.normalized_label and p.family = t.family
     where t.promoted_concept_id is not null
  )
  select distinct on (pr.concept_id, pr.parent_id)
         pr.concept_id, pr.parent_id, pr.family, pr.person_subtype,
         pr.confidence
    from proposals pr
    join ontology.concepts c on c.id = pr.concept_id and c.retired_at is null
    join ontology.concepts pc on pc.id = pr.parent_id and pc.retired_at is null
   where pr.parent_id <> pr.concept_id
     -- 0375's correction, in the bridge itself now: routing never crosses.
     and pc.concept_key not like 'hub:%'
     -- Eligibility: no standing edge, or only 0272's entry-genre edges.
     and not exists (
       select 1 from ontology.concept_edges e
        where e.ontology_version_id = old_version_id
          and e.subject_concept_id = pr.concept_id
          and e.predicate_key = 'broader' and e.status = 'active'
          and coalesce(e.provenance->>'source', '') <> '0272_kept_term_parent')
  order by pr.concept_id, pr.parent_id, pr.confidence desc;

  select count(distinct concept_id) into candidates from _bridge;
  if candidates = 0 then
    raise notice '0386: nothing to bridge here';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The dictionary''s placement answers become broader edges.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The congruence gate, judged at the new version.
  create temporary table _judged on commit drop as
  select b.*,
         semantic_private.concept_hub(b.parent_id, new_version_id) as parent_hub,
         (b.family <> 'person'
          or coalesce(semantic_private.concept_hub(b.parent_id, new_version_id), 'hub:music') = 'hub:music'
          or b.person_subtype in ('actor', 'director', 'character',
                                  'streamer', 'content_creator', 'comedian'))
           as congruent
    from _bridge b;

  select count(*) into refused from _judged where not congruent;
  select string_agg(distinct c.concept_key || ' -/-> ' || pc.concept_key, ', ')
    into refused_names
    from _judged j
    join ontology.concepts c on c.id = j.concept_id
    join ontology.concepts pc on pc.id = j.parent_id
   where not j.congruent;

  -- 0272's edges reject where a bridged answer replaces them.
  update ontology.concept_edges e
     set status = 'rejected'
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader' and e.status = 'active'
     and coalesce(e.provenance->>'source', '') = '0272_kept_term_parent'
     and e.subject_concept_id in (select concept_id from _judged where congruent);
  get diagnostics rejected_0272 = row_count;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, j.concept_id, 'broader', j.parent_id,
         least(1.0, j.confidence), 'learned',
         jsonb_build_object('source', '0386_dictionary_bridge'), 'active'
    from _judged j
   where j.congruent
  on conflict do nothing;
  get diagnostics bridged = row_count;

  if bridged = 0 then
    raise exception '0386: candidates existed and nothing bridged';
  end if;

  perform ontology.publish_version(new_version_id);

  -- Every bridged concept now blocks somewhere: the point of the exercise.
  if exists (
    select 1 from (select distinct concept_id from _judged where congruent) b
     where semantic_private.concept_block(b.concept_id, new_version_id) is null) then
    raise exception '0386: a bridged concept still blocks to nothing';
  end if;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': dictionary placements bridged to edges');

  raise notice '0386: % published — % edge(s) bridged onto % concept(s), % entry-genre edge(s) rejected, % refused by congruence: %',
    next_version, bridged, candidates, rejected_0272, refused,
    coalesce(refused_names, '(none)');
end;
$$;

commit;
