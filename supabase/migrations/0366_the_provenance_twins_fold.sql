-- 0366 — the provenance twins fold onto the identities they duplicate.
--
-- **The owner, 2026-08-25: "fold them."** Two concepts on the Memories page
-- were one entity wearing two keys: `creator:yt_UCritGVo7pLJLUS8wEu32vow`
-- ("i-dle (아이들)", minted from a channel id) beside catalogue
-- `creator:i_dle`, and `work:kept_0661e6feb938f088` ("Footloose: The
-- Musical (Original Broadway Cast Recording)") beside
-- `work:footloose_the_musical`. The twin rule generalises: a concept whose
-- key carries a provenance suffix (`yt_`, `kept_`, `channel_`) and whose
-- name — whole, parenthetical-stripped, or the parenthetical itself —
-- matches a same-kind catalogue concept's label is that concept, reached by
-- a route that could not see the catalogue row at mint time.
--
-- **Discovered by query, folded by 0357's shape, in one version.** Labels
-- re-issue on the winner (collision-guarded), the loser's revision goes
-- deprecated with `merged_into`, its edges reject; user assertions repoint
-- with version and concept moving together (the composite-key lesson 0357
-- bought) — except where the user already holds the winner under the same
-- predicate, where the loser's assertion retires instead: a fold must not
-- put one claim on the page twice. Promotion links and provisional
-- redirects follow. Nothing is deleted.
--
-- Replayable by asserting the transformation: the twins were minted at
-- runtime, a clean database holds none, and folding nothing is the correct
-- answer there.

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
  n               integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _twins on commit drop as
  with suffixed as (
    select c.id, c.concept_key, r.concept_kind, r.preferred_label,
           btrim(lower(regexp_replace(
             regexp_replace(r.preferred_label, '\s*\(.*\)$', ''),
             '[^a-z0-9À-￿]+', ' ', 'gi'))) as stripped,
           btrim(lower(regexp_replace(
             coalesce(substring(r.preferred_label from '\((.*)\)$'), ''),
             '[^a-z0-9À-￿]+', ' ', 'gi'))) as inner_label
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active'
    where c.retired_at is null
      and (c.concept_key like '%:yt\_%' escape '\'
           or c.concept_key like '%:kept\_%' escape '\'
           or c.concept_key like '%:channel\_%' escape '\')
  )
  select distinct s.id as loser_id, s.concept_key as loser_key,
         c2.id as winner_id, c2.concept_key as winner_key
  from suffixed s
  join ontology.concept_labels l2
    on l2.ontology_version_id = old_version_id and l2.status = 'active'
   and (l2.normalized_label = s.stripped
        or (s.inner_label <> '' and l2.normalized_label = s.inner_label))
  join ontology.concepts c2 on c2.id = l2.concept_id and c2.id <> s.id
   and c2.retired_at is null
   and c2.concept_key not like '%:yt\_%' escape '\'
   and c2.concept_key not like '%:kept\_%' escape '\'
   and c2.concept_key not like '%:channel\_%' escape '\'
  join ontology.concept_revisions r2
    on r2.concept_id = c2.id and r2.ontology_version_id = old_version_id
   and r2.status = 'active' and r2.concept_kind = s.concept_kind
  union
  -- **The dictionary bridge.** A twin whose own label is entirely the
  -- original language (ソードアート・オンライン) matches no catalogue label
  -- directly — but the dictionary holds both halves of its identity, and
  -- the english half names the catalogue concept. Same-kind, as ever.
  select distinct s.id, s.concept_key, c2.id, c2.concept_key
  from suffixed s
  join semantic_private.presumed_terms t
    on t.original_label = s.preferred_label
   and t.english_label is not null
   and t.english_label <> t.original_label
  join ontology.concept_labels l2
    on l2.ontology_version_id = old_version_id and l2.status = 'active'
   and l2.normalized_label = btrim(lower(regexp_replace(
         t.english_label, '[^a-z0-9À-￿]+', ' ', 'gi')))
  join ontology.concepts c2 on c2.id = l2.concept_id and c2.id <> s.id
   and c2.retired_at is null
   and c2.concept_key not like '%:yt\_%' escape '\'
   and c2.concept_key not like '%:kept\_%' escape '\'
   and c2.concept_key not like '%:channel\_%' escape '\'
  join ontology.concept_revisions r2
    on r2.concept_id = c2.id and r2.ontology_version_id = old_version_id
   and r2.status = 'active' and r2.concept_kind = s.concept_kind;

  -- A loser matching two winners is ambiguity, and ambiguity refuses.
  delete from _twins t where exists (
    select 1 from _twins o
    where o.loser_id = t.loser_id and o.winner_id <> t.winner_id);

  select count(*) into pairs_found from _twins;
  if pairs_found = 0 then
    raise notice '0366: no provenance twins here; nothing folds';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Provenance-suffixed twins fold onto the identities they duplicate.');
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
                                            'merged_by', '0366')
     where ontology_version_id = new_version_id
       and concept_id = pair.loser_id and status = 'active';

    -- One claim, once: retire the loser's assertion where the winner is
    -- already held under the same predicate; repoint the rest, version and
    -- concept moving together. **The repoint must exclude what the retire
    -- just handled** — a retired row still matches `concept_id = loser`,
    -- and moving it onto the winner collides with the very row that made
    -- it redundant (`user_assertion_concept_identity_idx`, which caught
    -- exactly this on the first deploy).
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

    raise notice '0366: % folds into % (% label(s) moved)',
      pair.loser_key, pair.winner_key, labels_moved;
  end loop;

  perform ontology.publish_version(new_version_id);

  -- Retired duplicates keep naming the loser — that is their record of
  -- having been superseded. What may not remain is a *standing* claim.
  if exists (
    select 1 from semantic_private.user_assertions a
     join _twins t on t.loser_id = a.concept_id
    where a.machine_state <> 'inactive') then
    raise exception '0366: a standing assertion still names a folded concept';
  end if;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || pairs_found || ' provenance twin(s) folded');
  raise notice '0366: % published — % pair(s) folded', next_version, pairs_found;
end;
$$;

commit;
