-- 0370 — two keeps of one identity fold onto the one the dictionary holds.
--
-- **The merge lapse the owner named (karina/Karina), mechanised.** The
-- capital-K Karina was minted by the early qwen-discovery route with only
-- 카리나 as its active labels; the later keep of "karina"
-- collision-checked normalized labels, found no Latin-script match, and
-- minted a second concept — label-script blindness, the same mechanism
-- 0366's dictionary bridge closed for kept-versus-catalogue, which that
-- migration deliberately never applied kept-to-kept. This one does:
--
-- **Two provenance-suffixed concepts whose identities meet through the
-- dictionary — the loser's label (any script) equals a promoted term's
-- english, original or canonical label, same kind — fold onto the concept
-- the dictionary promoted.** 0366's machinery verbatim: labels re-issue
-- collision-guarded, the loser's revision deprecates with `merged_into`,
-- assertions retire where the winner is already held and repoint
-- otherwise (version and concept together), promotion links and redirects
-- follow, ambiguity refuses, nothing is deleted.
--
-- Replayable by asserting the transformation: runtime keeps do not exist
-- on a clean database, and folding nothing is correct there.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  pair            record;
  pairs_found     integer := 0;
  labels_moved    integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _twins on commit drop as
  with dict as (
    select t.promoted_concept_id as winner_id,
           t.family,
           array_remove(array[
             btrim(lower(regexp_replace(t.english_label,  '[^a-z0-9À-￿]+', ' ', 'gi'))),
             btrim(lower(regexp_replace(t.original_label, '[^a-z0-9À-￿]+', ' ', 'gi'))),
             btrim(lower(regexp_replace(t.canonical_label,'[^a-z0-9À-￿]+', ' ', 'gi'))),
             t.normalized_label
           ], '') as identities
      from semantic_private.presumed_terms t
     where t.promoted_concept_id is not null
  )
  select distinct c.id as loser_id, c.concept_key as loser_key,
         d.winner_id, wc.concept_key as winner_key
    from dict d
    join ontology.concepts wc on wc.id = d.winner_id and wc.retired_at is null
    join ontology.concept_revisions wr
      on wr.concept_id = wc.id and wr.ontology_version_id = old_version_id
     and wr.status = 'active'
    join ontology.concept_labels l
      on l.ontology_version_id = old_version_id and l.status = 'active'
     and l.normalized_label = any(d.identities)
    join ontology.concepts c on c.id = l.concept_id
     and c.id <> d.winner_id and c.retired_at is null
     and (c.concept_key like '%:kept\_%' escape '\'
          or c.concept_key like '%:yt\_%' escape '\'
          or c.concept_key like '%:channel\_%' escape '\')
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active' and r.concept_kind = wr.concept_kind;

  -- Ambiguity refuses, both ways: a loser claimed by two winners, and a
  -- winner that is itself somebody's loser.
  delete from _twins t where exists (
    select 1 from _twins o
    where o.loser_id = t.loser_id and o.winner_id <> t.winner_id);
  delete from _twins t where exists (
    select 1 from _twins o where o.loser_id = t.winner_id);

  select count(*) into pairs_found from _twins;
  if pairs_found = 0 then
    raise notice '0370: no kept twins meet through the dictionary; nothing folds';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Kept twins of one dictionary identity fold onto the promoted concept.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  for pair in select * from _twins loop
    insert into ontology.concept_labels (
      ontology_version_id, concept_id, label, normalized_label, locale,
      label_type, provenance_type, confidence, status, external_ref)
    select new_version_id, pair.winner_id, l.label, l.normalized_label,
           l.locale,
           case when l.label_type = 'preferred' then 'alternate'
                else l.label_type end,
           l.provenance_type, l.confidence, 'active',
           coalesce(l.external_ref, '{}'::jsonb)
             || jsonb_build_object('merged_from', pair.loser_key)
      from ontology.concept_labels l
     where l.ontology_version_id = new_version_id
       and l.concept_id = pair.loser_id and l.status = 'active'
       and not exists (
         select 1 from ontology.concept_labels taken
          where taken.ontology_version_id = new_version_id
            and taken.status = 'active'
            and taken.normalized_label = l.normalized_label
            and taken.concept_id not in (pair.loser_id, pair.winner_id))
    on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
      do nothing;
    get diagnostics labels_moved = row_count;

    update ontology.concept_labels
       set status = 'deprecated'
     where ontology_version_id = new_version_id
       and concept_id = pair.loser_id and status = 'active';
    update ontology.concept_edges
       set status = 'rejected'
     where ontology_version_id = new_version_id
       and subject_concept_id = pair.loser_id and status = 'active';
    update ontology.concept_revisions
       set status = 'deprecated',
           metadata = coalesce(metadata, '{}'::jsonb)
                      || jsonb_build_object('merged_into', pair.winner_key,
                                            'merged_by', '0370')
     where ontology_version_id = new_version_id
       and concept_id = pair.loser_id and status = 'active';

    update semantic_private.user_assertions a
       set machine_state = 'inactive', updated_at = now()
     where a.concept_id = pair.loser_id
       and exists (
         select 1 from semantic_private.user_assertions w
          where w.user_id = a.user_id and w.concept_id = pair.winner_id
            and w.predicate_key = a.predicate_key);
    update semantic_private.user_assertions a
       set concept_id = pair.winner_id,
           created_ontology_version_id = new_version_id
     where a.concept_id = pair.loser_id
       and not exists (
         select 1 from semantic_private.user_assertions w
          where w.user_id = a.user_id and w.concept_id = pair.winner_id
            and w.predicate_key = a.predicate_key);

    update semantic_private.provisional_entities
       set redirect_concept_id = pair.winner_id
     where redirect_concept_id = pair.loser_id;
    update semantic_private.presumed_terms
       set promoted_concept_id = pair.winner_id
     where promoted_concept_id = pair.loser_id;
    update semantic_private.user_term_candidates
       set concept_id = pair.winner_id
     where concept_id = pair.loser_id;

    raise notice '0370: % folds into % (% label(s) moved)',
      pair.loser_key, pair.winner_key, labels_moved;
  end loop;

  perform ontology.publish_version(new_version_id);

  if exists (
    select 1 from semantic_private.user_assertions a
     join _twins t on t.loser_id = a.concept_id
    where a.machine_state <> 'inactive') then
    raise exception '0370: a standing assertion still names a folded concept';
  end if;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || pairs_found || ' kept twin(s) folded');
  raise notice '0370: % published — % pair(s) folded', next_version, pairs_found;
end;
$$;

commit;
