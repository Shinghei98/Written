-- 0397 — the filing climb reaches through the performer.
--
-- **The owner, 2026-08-25: "album, tours are also connect to person via
-- predicate. every performer can be assigned a default genre, use it."**
-- The connection half shipped: NIGHT DANCER carries an active
-- `performed_by` edge to IMASE (0374's promotion lane), IMASE carries
-- `broader -> genre:j_pop`, and the once-direct NIGHT DANCER genre edges
-- were rejected *in favour of* that route. What never shipped is the
-- "use it": `concept_block` climbs only `broader`, so the page stands one
-- predicate from the answer and files the song under Other — and the
-- kept-parent repair loop can never mend it, because the direct edge it
-- would re-add is the one the catalogue already rejected (the unique index
-- holds the rejected row, the insert conflicts, nothing changes, the guard
-- raises).
--
-- So the climb follows `performed_by` as well: a performance names the
-- identity whose placement speaks for the work on the page. Same
-- direction as `broader` (subject work -> object performer), same depth
-- budget, and the priority list is untouched — this changes what is
-- reachable, never what wins. Display-only and evaluated live at each
-- score's own version, so no rescore is owed.

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
     -- 0397: a work's performer places the work; everything else is
     -- containment. Two predicates, one direction, one depth budget.
     and edge.predicate_key in ('broader', 'performed_by')
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
