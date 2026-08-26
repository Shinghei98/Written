-- 0400 — the ladder reaches the page.
--
-- **The owner, 2026-08-26: build both — the ladder and the fallback.**
-- The three rows left in Other are the ladder's backlog (GRAMMARBOOK
-- §2.18): one context-join case and two no-identity cases. This is the
-- ladder's evidence side — the tiers that read stored evidence — while
-- the corpus side (pass-1/pass-2 in the parent build, tier-3 shape
-- constraints, tier-5 holds at mint) rides with the v21 run.
--
-- **Tier 2 — the entry binds the identity.** A blockless person's own
-- evidence rows name an album; the album's dictionary term states who
-- performs it; if every such path lands on exactly ONE placeable target,
-- the person joins it (`member_of_group`, learned) — Minnie's rows say
-- "DAHLIA / I burn - EP", the album's term says `performed_by i-dle`,
-- and i-dle files under K-Pop. **Two or more distinct targets refuse** —
-- the BLACKPINK-Lisa/LiSA rule: ranking never files an identity.
-- The album join is by verbatim canonical label: the album string on the
-- observation is the same string the dictionary ingested, and
-- `normalize_text` is a Unicode operation Postgres cannot reproduce
-- (0293) — verbatim matches what exists and refuses what it cannot see.
--
-- **The climb learns `member_of_group`** — a person files where their
-- group files, the same design as `performed_by` (0397) and
-- `composed_by` (0398).
--
-- **The fallback — a youtube-only person is a content creator.** Still
-- blockless after binding, kind `creator`, every accepted mapping from
-- the youtube lane: files under `subject:content_creators`. A rule on
-- lane and family — no name list — and it runs LAST, so a person the
-- context can place never falls through to it.
--
-- Ends with the recompute enqueue (0396's rule).

begin;

-- The climb, one predicate wider.
create or replace function semantic_private.concept_block(
  target_concept_id uuid, target_version_id uuid
) returns text
language sql
stable
set search_path to ''
as $function$
  with recursive blocks(block_key, priority) as (
    values
      ('genre:anime', 1), ('genre:classical', 2), ('genre:musicals', 3),
      ('genre:k_pop', 4), ('genre:j_pop', 5), ('genre:mandopop', 6),
      ('genre:cantopop', 7), ('genre:video_game', 8), ('subject:science', 9),
      ('subject:language_learning', 10), ('hub:news_current_affairs', 11),
      ('subject:travel', 12),
      ('subject:music_labels', 13), ('subject:entertainment_labels', 14),
      ('subject:content_creators', 15)
  ),
  climb(concept_id, depth) as (
    select target_concept_id, 0
    union all
    select edge.object_concept_id, climb.depth + 1
    from climb
    join ontology.concept_edges edge
      on edge.subject_concept_id = climb.concept_id
     -- A work files through its performer (0397) or composer (0398); a
     -- person files through their group (0400). Containment does the rest.
     and edge.predicate_key in ('broader', 'performed_by', 'composed_by',
                                'member_of_group')
     and edge.ontology_version_id = target_version_id
     and edge.status = 'active'
    where climb.depth < 8
  )
  select coalesce(
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
       join blocks b on b.block_key = c.concept_key
      order by b.priority, climb.depth, c.concept_key
      limit 1),
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'genre:%'
        and c.concept_key <> 'genre:asian_music'
      order by climb.depth, c.concept_key
      limit 1),
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'hub:%'
      order by climb.depth, c.concept_key
      limit 1)
  );
$function$;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  creators_id uuid;
  person record;
  bound integer := 0;
  ambiguous_held integer := 0;
  fell_back integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- The blockless persons, with each one's unique context target if the
  -- entry evidence names exactly one.
  create temporary table _held_persons on commit drop as
  select c.id as concept_id, c.concept_key
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active' and r.concept_kind = 'creator'
   where c.retired_at is null
     and semantic_private.concept_block(c.id, old_version_id) is null;

  create temporary table _bindings on commit drop as
  select hp.concept_id, targets.target_concept_id, targets.target_key,
         count(*) over (partition by hp.concept_id) as n_targets
    from _held_persons hp
    cross join lateral (
      select distinct opt.promoted_concept_id as target_concept_id,
             tc.concept_key as target_key
        from semantic_private.observation_mappings m
        join semantic_private.observations o
          on o.id = m.observation_id and o.user_id = m.user_id
        join semantic_private.presumed_terms apt
          on apt.canonical_label = o.normalized_payload ->> 'album'
         and apt.promoted_concept_id is not null
        join semantic_private.presumed_terms apt_all
          on apt_all.promoted_concept_id = apt.promoted_concept_id
        join semantic_private.presumed_term_relations rel
          on rel.subject_term_id = apt_all.id
         and rel.predicate in ('performed_by', 'member_of_group',
                               'part_of_franchise')
        join semantic_private.presumed_terms opt
          on opt.id = rel.object_term_id
         and opt.promoted_concept_id is not null
         and opt.promoted_concept_id <> hp.concept_id
        join ontology.concepts tc on tc.id = opt.promoted_concept_id
       where m.concept_id = hp.concept_id
         and m.mapping_state = 'accepted'
         and coalesce(o.normalized_payload ->> 'album', '') <> ''
         and semantic_private.concept_block(
               opt.promoted_concept_id, old_version_id) is not null
    ) targets;

  if not exists (select 1 from _held_persons) then
    raise notice '0400: no held persons stand; the ladder waits';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The ladder''s evidence tiers: entry-context binding and the creator fallback.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- Tier 2: one target, or none.
  for person in
    select distinct b.concept_id, b.target_concept_id, b.target_key,
           hp.concept_key, b.n_targets
      from _bindings b join _held_persons hp on hp.concept_id = b.concept_id
  loop
    if person.n_targets > 1 then
      ambiguous_held := ambiguous_held + 1;
      raise notice '0400: % names % targets — held', person.concept_key,
        person.n_targets;
      continue;
    end if;
    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key,
      object_concept_id, confidence, provenance_type, provenance, status)
    values (new_version_id, person.concept_id, 'member_of_group',
            person.target_concept_id, 0.85, 'learned',
            jsonb_build_object('rule', '0400 entry context binding'),
            'active')
    on conflict do nothing;
    bound := bound + 1;
    raise notice '0400: % binds to % by its own entries',
      person.concept_key, person.target_key;
  end loop;

  -- The fallback, over whoever the context could not place.
  select id into creators_id from ontology.concepts
   where concept_key = 'subject:content_creators';
  for person in
    select hp.concept_id, hp.concept_key from _held_persons hp
     where semantic_private.concept_block(hp.concept_id, new_version_id) is null
       and exists (select 1 from semantic_private.observation_mappings m
                    where m.concept_id = hp.concept_id
                      and m.mapping_state = 'accepted')
       and not exists (
         select 1 from semantic_private.observation_mappings m
         join semantic_private.observations o
           on o.id = m.observation_id and o.user_id = m.user_id
        where m.concept_id = hp.concept_id
          and m.mapping_state = 'accepted'
          and o.source_code <> 'youtube')
  loop
    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key,
      object_concept_id, confidence, provenance_type, provenance, status)
    values (new_version_id, person.concept_id, 'broader', creators_id,
            0.8, 'learned',
            jsonb_build_object('rule', '0400 youtube-only creator fallback'),
            'active')
    on conflict do nothing;
    fell_back := fell_back + 1;
    raise notice '0400: % is a content creator by lane', person.concept_key;
  end loop;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ladder tiers — ' || bound
    || ' bound by context, ' || ambiguous_held || ' held ambiguous, '
    || fell_back || ' filed as content creators');
  raise notice '0400: % published — % bound, % held, % fell back',
    next_version, bound, ambiguous_held, fell_back;
end;
$$;

commit;
