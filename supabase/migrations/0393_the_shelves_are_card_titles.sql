-- 0393 — the shelves are card titles.
--
-- **The owner, 2026-08-25: organizations shelve under "Music Labels" and
-- "Entertainment Labels", and those two titles are the card titles.** 0387
-- minted the shelves and 0392 put the organizations on them — verified at
-- published 0.41.3, `yg → subject:music_labels`. The page still filed the
-- three labels under MUSIC, because `concept_block`'s card-title list is a
-- closed priority list of thirteen keys, its second tier admits only
-- `genre:*`, and its third only `hub:*` — a `subject:*` shelf matches none
-- of the three, so the climb walks straight through it to `hub:music`.
--
-- The repair is two rows in the list the function already keeps: the
-- shelves join the card titles, after the topical subjects and ahead of
-- CONTENT CREATORS — an organization on a shelf is more specific than
-- "makes content", less specific than a genre. The list is hardcoded
-- because the owner's directive is ("organizations need to hardcode into
-- 'music labels', 'entertainment labels'"), which is how the other
-- thirteen got there too.
--
-- **No rescore.** `concept_block` is read live by `list_assertions` at
-- each score's own version; the edges it needs have stood at 0.41.3 since
-- 0392, so the heading changes the moment this function does.

begin;

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
      -- 0393: the two shelves the owner named as card titles.
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
     and edge.predicate_key = 'broader'
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
    -- The new tier: nearest genre by depth, containers excluded.
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

commit;
