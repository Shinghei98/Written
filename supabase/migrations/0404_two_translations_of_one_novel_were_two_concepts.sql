-- 0404 — two translations of one novel were two concepts.
--
-- **The owner's calibration of Timi's page found it (2026-08-26), and
-- the dictionary confesses it.** Timi liked David Tao's song
-- "討厭紅樓夢" ("Dislike Dream of the Red Chamber"); the model, applying
-- franchise-first to a literary allusion, stated the song
-- `part_of_franchise` of the novel — and the novel minted twice, once
-- per English rendering: `work:dream_of_the_red_chamber` (David's
-- corpus, filed under literature) and `work:red_chamber_dream` (Timi's,
-- inheriting mandopop from the song that merely mentions it). One
-- dictionary row for "Red Chamber Dream" already promotes to the
-- survivor — the identity layer knew, and never folded. The
-- translation-twin: same original name (紅樓夢), two renderings, two
-- concepts.
--
-- 0350's fold shape (via 0402's): labels re-issued on the survivor so
-- both renderings resolve there; children repointed; the twin's
-- mandopop edge rejected with the rest (a novel is not a genre of pop);
-- the twin's revision deprecated with `merged_into`. With 0403's reader
-- fix, Timi's inferred novel-row leaves her page — she liked a song,
-- not a book, and the song's mandopop-ness already lives in her David
-- Tao rows. Ends with the recompute enqueue.

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
   where concept_key = 'work:red_chamber_dream' and retired_at is null;
  select id into winner_id from ontology.concepts
   where concept_key = 'work:dream_of_the_red_chamber' and retired_at is null;

  if loser_id is null or winner_id is null then
    raise notice '0404: nothing to merge here (classical_music %, classical %)',
      loser_id is not null, winner_id is not null;
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'work:red_chamber_dream folds into work:dream_of_the_red_chamber.');
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
           || jsonb_build_object('merged_from', 'work:red_chamber_dream')
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
                    || jsonb_build_object('merged_into', 'work:dream_of_the_red_chamber',
                                          'merged_by', '0404')
   where ontology_version_id = new_version_id
     and concept_id = loser_id and status = 'active';

  if labels_moved = 0 then
    raise exception '0404: the merge moved no labels, which is not a merge';
  end if;
  if children_moved = 0 then
    raise notice '0404: the twin had no children to move — the labels were the point here';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': classical_music folds into classical — '
    || children_moved || ' child(ren) repointed, ' || labels_moved || ' label(s) moved');
  raise notice '0404: % published — % children, % labels',
    next_version, children_moved, labels_moved;
end;
$$;

commit;
