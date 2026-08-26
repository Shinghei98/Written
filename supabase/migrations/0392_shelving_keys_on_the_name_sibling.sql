-- 0392 — shelving keys on the organization's name-sibling.
--
-- The agencies' organization-family dictionary rows are unpromoted — the
-- franchise sibling won the mint — so a classification requiring an
-- organization row with a promotion found none, twice. The key is the
-- name: any promoted concept one of whose name-siblings is an
-- organization-family row classifies by whose stated relations feed that
-- name, exactly as 0391 counted them.

begin;

do $$
declare
  current_version text; next_version text;
  old_version_id uuid; new_version_id uuid;
  n integer; music_id uuid; ent_id uuid;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  select id into music_id from ontology.concepts where concept_key='subject:music_labels';
  select id into ent_id from ontology.concepts where concept_key='subject:entertainment_labels';
  if music_id is null then
    raise notice '0392: shelves absent here; nothing to classify'; return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Organizations shelve by their name-siblings.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  create temporary table _orgs on commit drop as
  select distinct c.id, t.normalized_label,
    (select count(*) from semantic_private.presumed_term_relations rel
      join semantic_private.presumed_terms obj on obj.id = rel.object_term_id
       and obj.normalized_label = t.normalized_label
      join semantic_private.presumed_terms st on st.id = rel.subject_term_id
      join ontology.concepts sc
        on sc.id = coalesce(st.promoted_concept_id, st.proposed_parent_concept_id)
      where semantic_private.concept_hub(sc.id, new_version_id) = 'hub:music')
      as music_feeders,
    (select count(*) from semantic_private.presumed_term_relations rel
      join semantic_private.presumed_terms obj on obj.id = rel.object_term_id
       and obj.normalized_label = t.normalized_label
      join semantic_private.presumed_terms st on st.id = rel.subject_term_id
      join ontology.concepts sc
        on sc.id = coalesce(st.promoted_concept_id, st.proposed_parent_concept_id)
      where semantic_private.concept_hub(sc.id, new_version_id) = 'hub:film_video')
      as screen_feeders
  from semantic_private.presumed_terms t
  join ontology.concepts c on c.id = t.promoted_concept_id
  where exists (select 1 from semantic_private.presumed_terms sib
                 where sib.normalized_label = t.normalized_label
                   and sib.family = 'organization')
    and not exists (select 1 from ontology.concept_edges e
      where e.ontology_version_id = new_version_id and e.status='active'
        and e.subject_concept_id = c.id and e.predicate_key = 'broader');

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, o.id, 'broader',
         case when o.music_feeders >= o.screen_feeders and o.music_feeders > 0
              then music_id
              when o.screen_feeders > 0 then ent_id end,
         0.8, 'learned', '{"source":"0392_label_shelves"}'::jsonb, 'active'
    from _orgs o where o.music_feeders > 0 or o.screen_feeders > 0
  on conflict do nothing;
  get diagnostics n = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || n || ' organization(s) shelved by name-sibling');
  raise notice '0392: % published — % shelved', next_version, n;
end;
$$;

commit;
