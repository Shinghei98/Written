-- 0385 — the drama heading un-folds from the subject it was misfiled on.
--
-- **The root cause the owner's Lucifer question exposed (2026-08-25).**
-- 0346-era twin-merge carried no kind guard, and the film slice's drama
-- genre folded onto `subject:drama` — a topic — leaving every label from
-- "drama film" to "television drama" hanging on a subject and no screen
-- drama heading anywhere for a placement to reach. The guard has existed
-- since 0356; this mints `genre:drama_film` from the same walk payload
-- (Q130232, 65 sitelinks) under `medium:screen_genres`, and moves the
-- film-shaped labels off the subject. The bare label "drama" stays with
-- `subject:drama` — one label, one owner, and the subject held it first.
-- A television-drama heading has no source entity (Wikidata's TV-genre
-- class holds only regional dramas, already imported) — not minted,
-- because a heading the source cannot name is a heading nobody authored.

begin;

create temporary table wikidata_payload (data jsonb) on commit drop;
insert into wikidata_payload values ($json$[{"k": "genre:drama_film", "kind": "genre", "l": "drama film", "d": "film genre", "labels": [["drama film", "drama film", "en", "preferred"], ["drama movie", "drama movie", "en", "alternate"], ["ドラマ映画", "ドラマ映画", "ja", "alternate"], ["드라마 영화", "드라마 영화", "ko", "alternate"], ["劇情片", "劇情片", "zh", "alternate"]], "parent": "medium:screen_genres", "qid": "Q130232", "sitelinks": 65, "slice": "film_genres"}]$json$::jsonb);

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  drama_id uuid;
  subject_id uuid;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  select id into subject_id from ontology.concepts where concept_key = 'subject:drama';
  if exists (select 1 from ontology.concepts where concept_key = 'genre:drama_film') then
    raise notice '0385: genre:drama_film already stands; nothing to repair';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The drama film genre un-folds from subject:drama.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  insert into ontology.concepts (id, concept_key)
  values (extensions.gen_random_uuid(), 'genre:drama_film');
  select id into drama_id from ontology.concepts where concept_key = 'genre:drama_film';

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, drama_id, entry->>'l', 'genre', entry->>'d',
         'ordinary', 'review_required', 'active',
         jsonb_build_object('source', 'wikidata', 'external_id', entry->>'qid',
                            'license', 'CC0-1.0', 'imported_by', '0385')
    from wikidata_payload, jsonb_array_elements(data) as entry;

  -- The film-shaped labels move: deprecated on the subject, active on the
  -- genre. The bare 'drama' label stays where it was.
  update ontology.concept_labels l
     set status = 'deprecated'
   where l.ontology_version_id = new_version_id and l.concept_id = subject_id
     and l.status = 'active'
     and l.normalized_label in ('drama film', 'television drama', 'drama movie');

  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, drama_id, lab->>0, lab->>1, lab->>2, lab->>3,
         'external', 1.0, 'active',
         jsonb_build_object('provider', 'wikidata', 'license', 'CC0-1.0')
    from wikidata_payload, jsonb_array_elements(data) as entry,
         jsonb_array_elements(entry->'labels') as lab
  on conflict do nothing;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, drama_id, 'broader', p.id, 1.0, 'curated',
         jsonb_build_object('source', '0385_drama_unfold'), 'active'
    from ontology.concepts p where p.concept_key = 'medium:screen_genres';

  perform ontology.publish_version(new_version_id);

  if semantic_private.concept_block(drama_id, new_version_id)
       is distinct from 'genre:drama_film' then
    raise exception '0385: drama_film blocks to %, expected itself',
      coalesce(semantic_private.concept_block(drama_id, new_version_id), '(nothing)');
  end if;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': the drama film heading un-folded');
  raise notice '0385: % published — genre:drama_film stands', next_version;
end;
$$;

commit;
