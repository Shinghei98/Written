-- 0462 — the song nominates its film, and the nomination conducts.
--
-- **The owner's directive (2026-08-28): the movie boilerplate belongs on
-- Veere Di Wedding, reached from the song the person actually plays.**
-- The dictionary already states `Tareefan part_of_franchise Veere Di
-- Wedding`; the franchise concept stands active with a curated-shaped
-- film identity (`broader -> genre:comedy_film`), so `bio_category`
-- already answers `movie` for it. Three floors stood between that and
-- the card, and this migration moves each by a rule, not a row:
--
-- 1. **The relation was never promoted.** 0377's stated-once floor ran
--    before both ends were promoted concepts. Re-run here, relations
--    only — franchise *mints* stay out, because 0460's recording-family
--    guard governs those and this migration mints nothing.
-- 2. **A stated-once edge could not conduct.** Promotion writes
--    confidence `0.4 + 0.1 x support`, so a stated-once franchise link
--    lands at 0.5 against `part_of_franchise`'s conduction floor of
--    0.65 — an edge that exists and carries nothing. Lowered to 0.50 in
--    the registry, the same posture as the works bar in 0459: the
--    owner's "one weak evidence is enough for now, calibrate later",
--    applied to the dial that was contradicting it.
-- 3. **A propagated claim had no witness.** The franchise assertion
--    propagation creates has no support links of its own, so the
--    YouTube witness rule withheld it however non-video its origin.
--    The witness now follows one conducting hop: support on a concept
--    whose edge conducts INTO the tested concept counts, under the
--    same channel test — so a Spotify-supported song witnesses its
--    film, and a YouTube-only tail stays held exactly as before.

begin;

-- ---------------------------------------------------------------
-- 1. The stated relations, promoted — 0377's floor, relations only.
-- ---------------------------------------------------------------
do $$
declare
  current_version text;
  old_version_id  uuid;
  next_version    text;
  new_version_id  uuid;
  edges_written   integer := 0;
  kind_refused    integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    return;  -- an empty database states nothing; the replay is clean
  end if;

  create temporary table _relations on commit drop as
  select s.promoted_concept_id as subject_id, r.predicate,
         o.promoted_concept_id as object_id,
         sum(r.observed_count) as support
    from semantic_private.presumed_term_relations r
    join semantic_private.presumed_terms s
      on s.id = r.subject_term_id and s.promoted_concept_id is not null
    join semantic_private.presumed_terms o
      on o.id = r.object_term_id and o.promoted_concept_id is not null
   where exists (select 1 from ontology.relation_types t
                  where t.predicate_key = r.predicate)
   group by 1, 2, 3;

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
     and sk.ontology_version_id = old_version_id and sk.status = 'active'
    join ontology.concept_revisions ok
      on ok.concept_id = rel.object_id
     and ok.ontology_version_id = old_version_id and ok.status = 'active'
   where rel.subject_id <> rel.object_id;

  select count(*) into kind_refused from _judged where not congruent;

  if not exists (
    select 1 from _judged j
     where j.congruent
       and not exists (
         select 1 from ontology.concept_edges e
          where e.ontology_version_id = old_version_id
            and e.subject_concept_id = j.subject_id
            and e.predicate_key = j.predicate
            and e.object_concept_id = j.object_id
            and e.status = 'active')) then
    raise notice '0462: nothing new to connect (% kind-refused)', kind_refused;
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (gen_random_uuid(), next_version, old_version_id, 'draft',
          '0462: stated relations connect — the song nominates its film.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, j.subject_id, j.predicate, j.object_id,
         least(0.9, 0.4 + 0.1 * j.support), 'learned',
         jsonb_build_object('source', '0374_relation_promotion',
                            'support', j.support, 'floor', 'stated_once_0462'),
         'active'
    from _judged j
   where j.congruent
     and not exists (
       select 1 from ontology.concept_edges held
        where held.ontology_version_id = new_version_id
          and held.subject_concept_id = j.subject_id
          and held.predicate_key = j.predicate
          and held.object_concept_id = j.object_id)
  on conflict do nothing;
  get diagnostics edges_written = row_count;

  perform ontology.publish_version(new_version_id);

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || edges_written
    || ' stated relation(s) connected, ' || kind_refused || ' kind-refused');
end;
$$;

-- ---------------------------------------------------------------
-- 2. The conduction floor meets the stated-once confidence.
-- ---------------------------------------------------------------
update ontology.relation_types
   set minimum_relation_confidence = 0.50
 where predicate_key = 'part_of_franchise'
   and minimum_relation_confidence > 0.50;

-- ---------------------------------------------------------------
-- 3. The witness follows one conducting hop.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION semantic_private.concept_has_non_video_witness(p_semantic_run_id uuid, p_concept_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
      from semantic_private.observation_mappings om
      join semantic_private.observations o on o.id = om.observation_id
      join semantic_private.sources s on s.source_code = o.source_code
     where om.semantic_run_id = p_semantic_run_id
       and om.concept_id = p_concept_id
       and om.mapping_state = 'accepted'
       and s.independence_group <> 'video'
  )
  -- 0458: the mention lane's evidence route, same channel test.
  or exists (
    select 1
      from semantic_private.semantic_runs run
      join semantic_private.user_term_candidates tc
        on tc.user_id = run.user_id and tc.concept_id = p_concept_id
      join semantic_private.candidate_support_links l
        on l.candidate_id = tc.id and l.user_id = tc.user_id
      join semantic_private.observations o on o.id = l.observation_id
      join semantic_private.sources s on s.source_code = o.source_code
     where run.id = p_semantic_run_id
       and s.independence_group <> 'video'
  )
  -- 0462: one conducting hop. A propagated claim's evidence lives on the
  -- concept it flowed from; support there counts here when the edge
  -- between them conducts under the registry's own gates — and the test
  -- is still the channel, so a video-only source witnesses nothing
  -- anywhere.
  or exists (
    select 1
      from semantic_private.semantic_runs run
      join ontology.concept_edges e
        on e.object_concept_id = p_concept_id
       and e.ontology_version_id = run.ontology_version_id
       and e.status = 'active'
      join ontology.relation_types t
        on t.predicate_key = e.predicate_key
       and t.propagation_weight > 0
       and coalesce(e.confidence, 1.0) >= t.minimum_relation_confidence
      join semantic_private.user_term_candidates tc
        on tc.user_id = run.user_id and tc.concept_id = e.subject_concept_id
      join semantic_private.candidate_support_links l
        on l.candidate_id = tc.id and l.user_id = tc.user_id
      join semantic_private.observations o on o.id = l.observation_id
      join semantic_private.sources s on s.source_code = o.source_code
     where run.id = p_semantic_run_id
       -- Mirrors PROPAGATION_EDGES' provenance gate exactly: promoted
       -- relations and any numbered reconciliation rule's edges conduct;
       -- a bare model statement does not.
       and (e.provenance_type in ('curated', 'provider')
            or (e.provenance_type = 'learned'
                and (e.provenance ->> 'source' = '0374_relation_promotion'
                     or e.provenance ->> 'rule' ~ '^[0-9]{4} ')))
       and s.independence_group <> 'video'
  );
$function$;

commit;
