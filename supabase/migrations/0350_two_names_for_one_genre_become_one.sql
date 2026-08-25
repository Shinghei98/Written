-- 0350 — `genre:musical_play` folds into `genre:musicals`.
--
-- **A curation seam the import created, found by the term it misled.**
-- `0346`'s twin-merge folds a fetched heading onto an existing concept when a
-- label matches exactly — no fuzziness, by this project's twice-paid rule —
-- and Wikidata's "musical play" shares no exact label with Apple's
-- "musicals", so both minted. The re-place run then offered three
-- musical-shaped candidates at once (`musicals`, `musical_play`,
-- `musical_improvisation`), splitting one concept-space, and `Jekyll & Hyde`
-- — a musical with "Musical … Cast Recording" in its own prompt — went to
-- `genre:pop`. A choice split among near-synonyms is the parallel-level
-- defect surviving inside the curated source itself.
--
-- **The merge is a version-level deprecation, not a deletion.** Concepts are
-- never deleted; at the new version `musical_play`'s revision goes
-- `deprecated` with `merged_into` in its metadata, its broader edge goes
-- `rejected`, its labels go `deprecated` — and every one of those labels is
-- re-issued on `genre:musicals`, so "musical play", "musical theatre" and
-- their locale variants resolve to the surviving concept. The old version
-- keeps its shape, which is what versions are for.
--
-- `genre:musical_improvisation` stays: improvising music is a different
-- thing from musical theatre, not a spelling of it.

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
  probe_key text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  select id into loser_id from ontology.concepts
   where concept_key = 'genre:musical_play' and retired_at is null;
  select id into winner_id from ontology.concepts
   where concept_key = 'genre:musicals' and retired_at is null;

  -- **Replayable by asserting the transformation, not the precondition.** On
  -- a database where 0346 never fetched musical_play (it always does in this
  -- chain, but the rule is the rule), there is nothing to merge and nothing
  -- to do.
  if loser_id is null or winner_id is null then
    raise notice '0350: nothing to merge here (musical_play %, musicals %)',
      loser_id is not null, winner_id is not null;
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'genre:musical_play merges into genre:musicals.');
  select id into new_version_id from ontology.versions where version = next_version;

  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The loser's labels, re-issued on the winner. Collision-guarded the same
  -- way every label insert in this chain is: a normalized form owned by a
  -- third concept is refused, and a second preferred label demotes to
  -- alternate.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, winner_id, l.label, l.normalized_label, l.locale,
         case when l.label_type = 'preferred' then 'alternate'
              else l.label_type end,
         l.provenance_type, l.confidence, 'active',
         coalesce(l.external_ref, '{}'::jsonb)
           || jsonb_build_object('merged_from', 'genre:musical_play')
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

  -- The loser steps down, at this version only.
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
                    || jsonb_build_object('merged_into', 'genre:musicals',
                                          'merged_by', '0350')
   where ontology_version_id = new_version_id
     and concept_id = loser_id and status = 'active';

  if labels_moved = 0 then
    raise exception '0350: the merge moved no labels, which is not a merge';
  end if;

  perform ontology.publish_version(new_version_id);

  -- **Read back through the vocabulary.** "musical play" must now resolve to
  -- the survivor, and the loser must resolve to nothing active.
  select c.concept_key into probe_key
    from ontology.concept_labels l
    join ontology.concepts c on c.id = l.concept_id
   where l.ontology_version_id = new_version_id and l.status = 'active'
     and l.normalized_label = 'musical play'
   limit 1;
  if probe_key is distinct from 'genre:musicals' then
    raise exception '0350: "musical play" resolves to %, expected genre:musicals',
      coalesce(probe_key, '(nothing)');
  end if;

  if exists (
    select 1 from ontology.concept_revisions r
     where r.ontology_version_id = new_version_id
       and r.concept_id = loser_id and r.status = 'active') then
    raise exception '0350: musical_play still holds an active revision';
  end if;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': musical_play merged into musicals');

  raise notice '0350: % published — % label(s) moved onto genre:musicals',
    next_version, labels_moved;
end;
$$;

commit;
