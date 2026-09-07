-- 0470 — an act records for its label.
--
-- **The regression 0469 caused, measured on the first recompute at
-- 0.41.33 (2026-09-07).** 0469 rejected every `creator part_of_franchise
-- X` edge, on the registry's own word that the predicate takes a work or
-- an event. Twenty-four of those edges pointed at organizations — "aespa
-- -> SM Entertainment", "BLACKPINK -> YG Entertainment", "KBS WORLD TV ->
-- KBS" — and they were the *only* conduit carrying an artist's weight to
-- their label or broadcaster: every organization assertion on every page
-- was λ-propagation along them and nothing else (KBS's own twelve
-- accepted channel mappings never scored it; the page had it through
-- LE SSERAFIM). The recompute's demotion sweep then retired nine
-- organization assertions across two users, and the "Music Labels" block
-- left David's page — against 0465, where the owner ruled that
-- organizations belong.
--
-- The rejection was right; the omission was not writing the statement
-- back under the predicate the container taxonomy (§2.21, 0398) reserves
-- for exactly this: **`signed_to_label` — "an act records for a named
-- label organization."** 0398 restated the dictionary rows that way and
-- nothing ever promoted them to edges. So each rejected person->
-- organization edge is restated here as a `signed_to_label` edge with the
-- confidence 0374 gave the statement, provenance naming the edge it
-- restates. Where the organization is the platform itself (the one whose
-- label is a registered source code — YouTube — 0398's rule), the
-- restatement is `platform_of`, which the registry weights at zero:
-- publishing on a platform is not taste, and PewDiePie does not make
-- somebody like YouTube.
--
-- **What returns and what waits, and why that is the registry's call.**
-- `signed_to_label` conducts at λ 0.20 above confidence 0.65; 0374 priced a
-- statement at 0.5 + 0.1 per further sighting. So the labels stated three
-- or more times conduct again now (SM Entertainment and YG Entertainment,
-- for both users who had them), while the once- or twice-stated ones
-- (KBS, MBC, STUDIO CHOOM, Big Hit, SAYMYNAME) stand as recorded edges
-- and wait for support. The old conduit cleared at 0.50 only because it
-- was the wrong predicate. Whether a label deserves the franchise floor
-- is a registry number, fitted and recorded in PROJECT-CONTEXT, and this
-- migration does not move it; the owner can.
--
-- Nothing else moves: persons still never subject `part_of_franchise`,
-- and the works, games, films and genres the same recompute retired were
-- reached only through a performer's forward weight, which the registry
-- gives no predicate (`performed_by` carries zero reverse weight) — the
-- intended loss, not a regression. Ends with the recompute enqueue.
begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  n_label         integer := 0;
  n_platform      integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '0470: no published version; nothing to restate';
    return;
  end if;

  -- The statements to restate: 0469's person-subject rejections whose
  -- object is an organization still standing, less any already restated.
  create temporary table _restate on commit drop as
  select e.id as edge_id, e.subject_concept_id, e.object_concept_id,
         e.confidence, e.provenance,
         case when exists (
                select 1 from semantic_private.presumed_terms t
                 where t.promoted_concept_id = e.object_concept_id and t.family = 'platform')
              or lower(btrim(o.preferred_label)) in (select source_code from semantic_private.sources)
              then 'platform_of' else 'signed_to_label' end as predicate
    from ontology.concept_edges e
    join ontology.concept_revisions o
      on o.concept_id = e.object_concept_id
     and o.ontology_version_id = old_version_id and o.status = 'active'
     and o.concept_kind = 'organization'
   where e.ontology_version_id = old_version_id
     and e.predicate_key = 'part_of_franchise' and e.status = 'rejected'
     and e.provenance->>'rejected_by' = '0469'
     and e.provenance->>'reason' = 'person_subject'
     and not exists (
       select 1 from ontology.concept_edges r
        where r.ontology_version_id = old_version_id
          and r.subject_concept_id = e.subject_concept_id
          and r.object_concept_id = e.object_concept_id
          and r.predicate_key in ('signed_to_label', 'platform_of')
          and r.status = 'active');

  if not exists (select 1 from _restate) then
    raise notice '0470: every label statement is already restated; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'An act records for its label: person->organization statements restated as signed_to_label.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, r.subject_concept_id, r.predicate, r.object_concept_id,
         r.confidence, 'learned',
         jsonb_build_object('rule', '0470 an act records for its label',
                            'restates', r.edge_id,
                            'support', r.provenance->>'support'),
         'active'
    from _restate r
  on conflict do nothing;

  select count(*) filter (where predicate = 'signed_to_label'),
         count(*) filter (where predicate = 'platform_of')
    into n_label, n_platform from _restate;

  -- The transformation, asserted: at the new version every rejected
  -- person->organization statement has a standing restatement.
  if exists (
    select 1 from _restate r
     where not exists (
       select 1 from ontology.concept_edges n
        where n.ontology_version_id = new_version_id
          and n.subject_concept_id = r.subject_concept_id
          and n.object_concept_id = r.object_concept_id
          and n.predicate_key = r.predicate and n.status = 'active'))
  then
    raise exception '0470: a person->organization statement is still without its restatement';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || n_label || ' signed_to_label and '
    || n_platform || ' platform_of edge(s) restate the rejected person->organization statements');
  raise notice '0470: % published — % signed_to_label, % platform_of', next_version, n_label, n_platform;
end $$;

commit;
