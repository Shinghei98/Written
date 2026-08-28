-- 0453 — the block is the medium; the hub is only where the evidence came from.
--
-- **Why the watchable works were silent or mislabeled.** `bio_category`'s
-- work branch tested the hub first, so an anime reached through its game
-- (Persona 5, Sword Art Online) read as a game, one reached through its
-- soundtrack (Attack on Titan) read as nothing, and only one reached as
-- watched media (One Piece) fell through to the dormant `screen`. Musicals
-- (Wicked, Musical Jekyll & Hyde) carry a clean `genre:musicals` block and
-- matched no branch at all. The taxonomy was already right — `concept_block`
-- reliably names the medium-genre — and the category rule was reading the
-- wrong column of it.
--
-- **The owner's direction (2026-08-28): anime wins over game**, and the
-- musical joins the same watchable family. So for a work, the medium-genre
-- block now outranks the hub: `genre:anime` and `genre:musicals` categorize
-- `tv_series` — the shipped client vocabulary's watchable category, so no
-- app change is needed — before the games hub can claim the term. The
-- regexes stay: a future `genre:*_series` block is still caught, and movies
-- (`genre:*_film`) already worked.
--
-- No state is touched and nothing re-scores: `bio_category` is evaluated at
-- read time by `matching_terms`, so the surfaces change on their next call.

begin;

CREATE OR REPLACE FUNCTION semantic_private.bio_category(target_concept_id uuid, target_version_id uuid, target_kind text, target_predicate text, block_key text, hub_key text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case
    when target_concept_id is null then 'other'
    -- The concept's own key, one PK lookup.
    when exists (select 1 from ontology.concepts c
                  where c.id = target_concept_id
                    and c.concept_key like 'travel:%') then 'travel'
    when target_predicate = 'participates_in_activity'
         and exists (select 1 from ontology.concepts c
                      where c.id = target_concept_id
                        and c.concept_key like 'activity:%')
      then 'sport_doing'
    when target_kind = 'creator' then
      case
        when block_key = 'genre:classical'
             or exists (select 1 from ontology.concept_edges e
                         where e.object_concept_id = target_concept_id
                           and e.predicate_key = 'composed_by'
                           and e.status = 'active'
                           and e.ontology_version_id = target_version_id)
          then 'composer'
        when block_key = 'subject:content_creators' then 'creator'
        when hub_key = 'hub:music'
             or exists (select 1 from ontology.concept_edges e
                         where e.object_concept_id = target_concept_id
                           and e.predicate_key = 'performed_by'
                           and e.status = 'active'
                           and e.ontology_version_id = target_version_id)
          then 'performer'
        else 'other'
      end
    when target_kind = 'work' then
      case
        -- 0453: the medium-genre block outranks the hub. An anime reached
        -- through its game or its soundtrack is still an anime, and a
        -- musical is watchable whatever shelf its recording sat on.
        when block_key = 'genre:anime' then 'tv_series'
        when block_key = 'genre:musicals' then 'tv_series'
        when hub_key = 'hub:games_play' then 'game'
        when block_key = 'medium:literary_genres'
             or exists (select 1 from ontology.concept_revisions r
                         where r.concept_id = target_concept_id
                           and r.ontology_version_id = target_version_id
                           and r.status = 'active'
                           and r.metadata ->> 'work_type' = 'book')
          then 'book'
        when block_key ~ '^genre:.*(television|drama|sitcom|show|series)'
          then 'tv_series'
        when block_key ~ '^genre:.*(film|movie|bollywood|noir)$'
             or block_key ~ '_film$'
          then 'movie'
        when hub_key = 'hub:film_video' then 'screen'
        else 'other'
      end
    when block_key = 'subject:language_learning'
         or exists (select 1 from ontology.concepts c
                     where c.id = target_concept_id
                       and c.concept_key like 'subject:%_language')
      then 'subject_language'
    when hub_key = 'hub:ideas_learning'
         and exists (select 1 from ontology.concepts c
                      where c.id = target_concept_id
                        and c.concept_key like 'subject:%')
      then 'subject'
    else 'other'
  end;
$function$;

commit;
