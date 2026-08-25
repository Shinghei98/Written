-- 0377 — identity mints, weight measures: the support floor leaves the
--          mint-and-connect path.
--
-- **The owner's correction, 2026-08-25: "MCU should still be minted,
-- despite the weight being extremely low — thus below cutoff."** The
-- founding principle applied consistently: inferred terms exist to expand
-- the global vocabulary; many exist at low weight and that is correct;
-- the display cutoff is what handles noise. 0374's support >= 2 floor
-- conflated identity with evidence — and it was miscalibrated besides: a
-- work states its franchise about once, so per-pair support of 2 refused
-- the ordinary case (Iron Man -> MCU is n=1 forever).
--
-- Two acts, both identity-gated and support-free:
--
-- 1. **Franchise objects of stated relations mint.** A dictionary
--    franchise row that is the object of any `part_of_franchise`
--    statement, unpromoted, with an unambiguous identity — its label
--    names nothing else, its english half is present — mints through
--    0337's convention (franchise -> work: prefix, kind work). The
--    disambiguation ladder's tier-5 still holds: a label naming two
--    things refuses. Weight stays whatever the evidence gives it —
--    usually a whisper below every cutoff, which is the design.
--
-- 2. **The relation floor drops to stated-once.** Same gates as 0374
--    minus the floor: both ends promoted, registered predicate,
--    per-predicate kind agreement. A wrong statement now crosses at tiny
--    conductance and dies below the cutoff, exactly as the owner's
--    weighting model prescribes; the strike lane and the binding-context
--    ladder price and prevent, respectively.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  minted          integer := 0;
  ambiguous_refused integer := 0;
  edges_written   integer := 0;
  kind_refused    integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- ---------------------------------------------------------------
  -- 1. The unpromoted franchise objects, identity-gated.
  -- ---------------------------------------------------------------
  create temporary table _franchise_mints on commit drop as
  select distinct t.id as term_id, t.canonical_label,
         coalesce(nullif(t.english_label, ''), t.canonical_label) as name,
         'work:' || btrim(regexp_replace(
             lower(coalesce(nullif(t.english_label, ''), t.canonical_label)),
             '[^a-z0-9]+', '_', 'g'), '_') as concept_key
    from semantic_private.presumed_term_relations r
    join semantic_private.presumed_terms t
      on t.id = r.object_term_id and t.family = 'franchise'
     and t.promoted_concept_id is null
   where r.predicate = 'part_of_franchise';

  -- Ambiguity refuses: the name may match no active label of any other
  -- concept, and no two mints may claim one key.
  delete from _franchise_mints m
   where exists (
     select 1 from ontology.concept_labels l
      join ontology.concepts c on c.id = l.concept_id
      where l.ontology_version_id = old_version_id and l.status = 'active'
        and l.normalized_label = lower(btrim(m.name))
        and c.retired_at is null)
      or exists (select 1 from ontology.concepts c2
                  where c2.concept_key = m.concept_key)
      or exists (select 1 from _franchise_mints o
                  where o.concept_key = m.concept_key and o.term_id <> m.term_id);
  get diagnostics ambiguous_refused = row_count;

  -- ---------------------------------------------------------------
  -- 2. The relations, stated-once, kind-agreed.
  -- ---------------------------------------------------------------
  create temporary table _relations on commit drop as
  select s.promoted_concept_id as subject_id, r.predicate,
         coalesce(o.promoted_concept_id,
                  (select null::uuid)) as object_id,
         o.id as object_term_id,
         sum(r.observed_count) as support
    from semantic_private.presumed_term_relations r
    join semantic_private.presumed_terms s
      on s.id = r.subject_term_id and s.promoted_concept_id is not null
    join semantic_private.presumed_terms o on o.id = r.object_term_id
   where exists (select 1 from ontology.relation_types t
                  where t.predicate_key = r.predicate)
   group by 1, 2, 3, 4;

  if not exists (select 1 from _franchise_mints)
     and not exists (
       select 1 from _relations rel
        where rel.object_id is not null
          and not exists (
            select 1 from ontology.concept_edges e
             where e.ontology_version_id = old_version_id
               and e.subject_concept_id = rel.subject_id
               and e.predicate_key = rel.predicate
               and e.object_concept_id = rel.object_id
               and e.status = 'active')) then
    raise notice '0377: nothing new to mint or connect here';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Identity mints and weight measures: franchises mint support-free; relations connect stated-once.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- Mint the franchises.
  insert into ontology.concepts (id, concept_key)
  select extensions.gen_random_uuid(), m.concept_key from _franchise_mints m
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, m.name, 'work', null,
         'ordinary', 'review_required', 'active',
         jsonb_build_object('origin', '0377_franchise_mint',
                            'family', 'franchise')
    from _franchise_mints m
    join ontology.concepts c on c.concept_key = m.concept_key
  on conflict (ontology_version_id, concept_id) do nothing;
  get diagnostics minted = row_count;

  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, m.name, lower(btrim(m.name)), 'en',
         'preferred', 'learned', 0.9, 'active',
         jsonb_build_object('origin', '0377_franchise_mint')
    from _franchise_mints m
    join ontology.concepts c on c.concept_key = m.concept_key
  on conflict do nothing;

  update semantic_private.presumed_terms t
     set promoted_concept_id = c.id, promoted_at = now()
    from _franchise_mints m
    join ontology.concepts c on c.concept_key = m.concept_key
   where t.id = m.term_id and t.promoted_concept_id is null;

  -- Refresh objects now promoted, then judge kinds and connect.
  update _relations rel
     set object_id = t.promoted_concept_id
    from semantic_private.presumed_terms t
   where t.id = rel.object_term_id and rel.object_id is null
     and t.promoted_concept_id is not null;

  create temporary table _judged on commit drop as
  select rel.*,
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
     and ok.ontology_version_id = new_version_id and ok.status = 'active'
   where rel.object_id is not null and rel.subject_id <> rel.object_id;

  select count(*) into kind_refused from _judged where not congruent;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, j.subject_id, j.predicate, j.object_id,
         least(0.9, 0.4 + 0.1 * j.support), 'learned',
         jsonb_build_object('source', '0374_relation_promotion',
                            'support', j.support, 'floor', 'stated_once_0377'),
         'active'
    from _judged j
   where j.congruent
  on conflict do nothing;
  get diagnostics edges_written = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || minted || ' franchise(s) minted, '
    || edges_written || ' relation(s) connected stated-once');
  raise notice '0377: % published — % minted (% ambiguous refused), % edge(s) (% kind-refused)',
    next_version, minted, ambiguous_refused, edges_written, kind_refused;
end;
$$;

commit;
