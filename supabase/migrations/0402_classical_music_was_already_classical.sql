-- 0402 — classical music was already classical.
--
-- **Found by the owner on the page, 2026-08-26: one album alone under a
-- "CLASSICAL MUSIC" heading beside the 26-row CLASSICAL card.** The
-- vocabulary holds two concepts for one referent — `genre:classical`
-- (653 children, on the card-title list) and `genre:classical_music`
-- (a twin, 5 children) — siblings under `medium:music_genres` with no
-- path between them, so the climb can never carry the twin's children to
-- the real card. Same string-inequality mint as "k-pop"/"k pop" (0379),
-- one layer up: a stated "Classical Music" minted beside "Classical"
-- instead of resolving to it.
--
-- The fold is 0350's shape — labels re-issued on the survivor so every
-- future stated string resolves there, the twin's revision deprecated
-- with `merged_into`, its out-edges rejected — plus the part 0350 never
-- needed: **the twin's children repoint to the survivor**, skipping any
-- child that already reaches it. Ends with the recompute enqueue.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  loser_id  uuid;
  winner_id uuid;
  labels_moved integer;
  children_moved integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  select id into loser_id from ontology.concepts
   where concept_key = 'genre:classical_music' and retired_at is null;
  select id into winner_id from ontology.concepts
   where concept_key = 'genre:classical' and retired_at is null;

  if loser_id is null or winner_id is null then
    raise notice '0402: nothing to merge here (classical_music %, classical %)',
      loser_id is not null, winner_id is not null;
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'genre:classical_music folds into genre:classical.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The twin's children move onto the survivor — the part this fold
  -- exists for. A child already reaching the survivor keeps that edge
  -- and its twin edge is rejected instead of duplicated.
  update ontology.concept_edges e
     set object_concept_id = winner_id
   where e.ontology_version_id = new_version_id
     and e.object_concept_id = loser_id
     and e.status = 'active'
     and not exists (
       select 1 from ontology.concept_edges dup
        where dup.ontology_version_id = new_version_id
          and dup.subject_concept_id = e.subject_concept_id
          and dup.predicate_key = e.predicate_key
          and dup.object_concept_id = winner_id);
  get diagnostics children_moved = row_count;

  update ontology.concept_edges e
     set status = 'rejected'
   where e.ontology_version_id = new_version_id
     and e.object_concept_id = loser_id
     and e.status = 'active';

  -- Labels re-issued on the survivor, collision-guarded as always.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, winner_id, l.label, l.normalized_label, l.locale,
         case when l.label_type = 'preferred' then 'alternate'
              else l.label_type end,
         l.provenance_type, l.confidence, 'active',
         coalesce(l.external_ref, '{}'::jsonb)
           || jsonb_build_object('merged_from', 'genre:classical_music')
    from ontology.concept_labels l
   where l.ontology_version_id = new_version_id
     and l.concept_id = loser_id
     and l.status = 'active'
     and not exists (
       select 1 from ontology.concept_labels taken
        where taken.ontology_version_id = new_version_id
          and taken.status = 'active'
          and taken.normalized_label = l.normalized_label
          and taken.concept_id not in (loser_id, winner_id))
  on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
    do nothing;
  get diagnostics labels_moved = row_count;

  update ontology.concept_labels
     set status = 'deprecated'
   where ontology_version_id = new_version_id
     and concept_id = loser_id and status = 'active';

  update ontology.concept_edges
     set status = 'rejected'
   where ontology_version_id = new_version_id
     and subject_concept_id = loser_id and status = 'active';

  update ontology.concept_revisions
     set status = 'deprecated',
         metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('merged_into', 'genre:classical',
                                          'merged_by', '0402')
   where ontology_version_id = new_version_id
     and concept_id = loser_id and status = 'active';

  if labels_moved = 0 then
    raise exception '0402: the merge moved no labels, which is not a merge';
  end if;
  if children_moved = 0 then
    raise exception '0402: the merge moved no children, and the children were the point';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': classical_music folds into classical — '
    || children_moved || ' child(ren) repointed, ' || labels_moved || ' label(s) moved');
  raise notice '0402: % published — % children, % labels',
    next_version, children_moved, labels_moved;
end;
$$;

commit;
