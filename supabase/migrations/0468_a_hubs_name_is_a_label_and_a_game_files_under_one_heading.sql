-- 0468 — a hub's name is a label, and a game files under one heading.
--
-- Two failures behind one sighting (owner, 2026-09-06): David's Memories
-- page showed "Games & play" and "Games" as two headings over three games,
-- Final Fantasy XIV and Hearthstone under the first, Clever Prisoner under
-- the second, all three climbing to `hub:games_play`.
--
-- 1. **The block.** `concept_block` (0157, restated through 0400) named
--    `genre:video_game` a block of its own. That concept is the *music*
--    genre "Video Game" of 0066, provider-labelled "Games", which 0154
--    parented under the games hub's genre layer. A game that reaches the
--    hub through that genre stopped at it and read "Games"; a game parented
--    straight to the hub — the seed CSV, the Wikidata game slices — fell to
--    the hub fallback and read "Games & play". On production 306 works take
--    the second route and 11 the first. The block for games is the hub. The
--    genre keeps its place in the graph; it stops being a heading.
--
-- 2. **The shadow.** `work:games_play` is a franchise mint of 0377, from one
--    model-stated `part_of_franchise` whose object was the hub's own display
--    name. 0379 retired 0377's shadows by matching the properly-normalized
--    name against active *label rows* — and the hub has no row for "Games &
--    play": its rows carry only the Wikidata heading "Video_game_culture",
--    its name living in `concept_revisions.preferred_label` alone. 266
--    concepts at the published version are in that state (187 works, 26
--    topics, 17 genres, 14 hubs, ...), so every guard that reads the label
--    table is blind to their names. Two acts, in one new version:
--    - every active concept's preferred label becomes a `preferred` label
--      row, so the label table is the complete index of names that 0377's
--      guard, 0379's fold and the twin-merge already assume it is;
--    - 0379's fold runs once more, this time through the preferred label:
--      a 0377/0378 mint whose normalized name equals an older, unretired
--      concept's normalized preferred label is deprecated with
--      `merged_into`, its edges rejected, its dictionary promotion unwound,
--      its assertions retired. Nothing is deleted. On production that is
--      nine: three hub shadows (games & play; work, study & making; books,
--      ideas & learning) and six YouTube channels minted as franchises of
--      themselves.
--
-- Replayable by asserting the transformation: a database with nothing to
-- label and nothing to fold publishes no version, and the block rule is
-- asserted on the two games only where they exist.

begin;

-- ---------------------------------------------------------------------
-- 1. The block: the games hub is the heading; the music genre is not.
-- ---------------------------------------------------------------------
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
      ('genre:cantopop', 7),
      -- 0468: the hub, not `genre:video_game` — a music genre that sits
      -- under this hub and split its games into two headings.
      ('hub:games_play', 8), ('subject:science', 9),
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

-- The rule, asserted on the two routes where they exist: a game reached
-- through the music genre and a game parented straight to the hub file
-- under the same heading.
do $$
declare
  published_id uuid;
  via_genre    text;
  via_hub      text;
begin
  select id into published_id from ontology.versions where status = 'published';
  select semantic_private.concept_block(c.id, published_id) into via_genre
    from ontology.concepts c where c.concept_key = 'work:clever_prisoner';
  select semantic_private.concept_block(c.id, published_id) into via_hub
    from ontology.concepts c where c.concept_key = 'work:final_fantasy_xiv';
  if via_genre is not null and via_genre <> 'hub:games_play' then
    raise exception '0468: a game reached through genre:video_game files under %, not the hub', via_genre;
  end if;
  if via_hub is not null and via_hub <> 'hub:games_play' then
    raise exception '0468: a game under the hub files under %, not the hub', via_hub;
  end if;
  raise notice '0468: block rule holds (through the genre: %, under the hub: %)',
    coalesce(via_genre, 'absent'), coalesce(via_hub, 'absent');
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Every name is a label, and the shadows the missing labels hid retire.
-- ---------------------------------------------------------------------
do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  unlabelled      integer := 0;
  labelled        integer := 0;
  retired         integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '0468: no published version; nothing to label or fold';
    return;
  end if;

  -- The shadows: 0379's rule, read through the preferred label. The match
  -- must predate the mint — an older concept, never a fellow mint.
  create temporary table _shadows on commit drop as
  select distinct c.id as shadow_id, c.concept_key as shadow_key,
         older.concept_key as original_key
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
    join ontology.concept_revisions orr
      on orr.ontology_version_id = old_version_id and orr.status = 'active'
     and btrim(regexp_replace(lower(orr.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))
       = btrim(regexp_replace(lower(r.preferred_label),   '[^a-z0-9À-￿]+', ' ', 'g'))
    join ontology.concepts older
      on older.id = orr.concept_id and older.id <> c.id
     and older.retired_at is null and older.created_at < c.created_at
   where r.ontology_version_id = old_version_id and r.status = 'active'
     and r.metadata->>'origin' in ('0377_franchise_mint', '0378_provider_topic');

  select count(*) into unlabelled
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
   where r.ontology_version_id = old_version_id and r.status = 'active'
     and btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g')) <> ''
     and not exists (
       select 1 from ontology.concept_labels l
        where l.concept_id = r.concept_id
          and l.ontology_version_id = old_version_id and l.status = 'active'
          and l.normalized_label
              = btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g')));

  if unlabelled = 0 and not exists (select 1 from _shadows) then
    raise notice '0468: every name is already a label and no shadow stands; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Every preferred label is a label row; the shadows it hid retire.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- 2a. The preferred label as a label row, at the new version, for every
  -- active concept that lacks one. Locale follows the script, as the
  -- catalogue's own rows do: ASCII names are `en`, anything else `und`.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status)
  select new_version_id, r.concept_id, r.preferred_label,
         btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g')),
         case when r.preferred_label ~ '[^\x00-\x7F]' then 'und' else 'en' end,
         'preferred', 'curated', 1.0, 'active'
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_id not in (select shadow_id from _shadows)
     and btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g')) <> ''
     and not exists (
       select 1 from ontology.concept_labels l
        where l.concept_id = r.concept_id
          and l.ontology_version_id = new_version_id and l.status = 'active'
          and l.normalized_label
              = btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g')))
  on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;
  get diagnostics labelled = row_count;

  -- 2b. The fold, as 0379 did it: labels deprecated, edges rejected, the
  -- revision deprecated with `merged_into`, the dictionary unwound, the
  -- assertions retired. Nothing is deleted.
  update ontology.concept_labels
     set status = 'deprecated'
   where ontology_version_id = new_version_id
     and concept_id in (select shadow_id from _shadows) and status = 'active';

  update ontology.concept_edges
     set status = 'rejected'
   where ontology_version_id = new_version_id and status = 'active'
     and (subject_concept_id in (select shadow_id from _shadows)
          or object_concept_id in (select shadow_id from _shadows));

  update ontology.concept_revisions r
     set status = 'deprecated',
         metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('merged_into', s.original_key,
                                          'merged_by', '0468')
    from _shadows s
   where r.ontology_version_id = new_version_id
     and r.concept_id = s.shadow_id and r.status = 'active';
  get diagnostics retired = row_count;

  update semantic_private.presumed_terms
     set promoted_concept_id = null, promoted_at = null
   where promoted_concept_id in (select shadow_id from _shadows);

  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where concept_id in (select shadow_id from _shadows)
     and machine_state <> 'inactive';

  -- The transformation, asserted: at the new version no active concept's
  -- name is missing from the label table, and no shadow still stands.
  if exists (
    select 1 from ontology.concept_revisions r
     join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
    where r.ontology_version_id = new_version_id and r.status = 'active'
      and btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g')) <> ''
      and not exists (
        select 1 from ontology.concept_labels l
         where l.concept_id = r.concept_id
           and l.ontology_version_id = new_version_id and l.status = 'active'
           and l.normalized_label
               = btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))))
  then
    raise exception '0468: a concept still has no label row for its preferred label';
  end if;
  if exists (
    select 1 from ontology.concept_revisions r join _shadows s on s.shadow_id = r.concept_id
     where r.ontology_version_id = new_version_id and r.status = 'active')
  then
    raise exception '0468: a shadow is still active at the new version';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || labelled || ' name(s) became labels, '
    || retired || ' shadow(s) retired onto their originals');
  raise notice '0468: % published — % name(s) became labels, % shadow(s) retired',
    next_version, labelled, retired;
end;
$$;

commit;
