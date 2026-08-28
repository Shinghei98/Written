-- 0455 — a stated game parent outranks the anime block.
--
-- **0453 over-read the block.** `concept_block` gives `genre:anime`
-- priority 1, so a work reaching both anime and a game genre blocks as
-- anime — and 0453, keyed on the block, called Final Fantasy VII Rebirth
-- (`broader -> genre:role_playing_game` AND `genre:anime`) a series. The
-- block is a climb artifact; the work's own direct parents state the
-- medium: a work filed under a game genre is a game, whatever aesthetic
-- edges it also carries. The owner's correction, 2026-08-28: FF7 and FF
-- are game franchises.
--
-- The detector is the parent's hub, not a name list: `genre:video_game`
-- and `genre:role_playing_game` both live under `hub:games_play`, and a
-- game genre minted later lands there too. Consequences on the live data:
-- FF7 Rebirth and Persona 5 return to `game`; Attack on Titan and One
-- Piece (anime edges only) stay `tv_series`; Sword Art Online carries a
-- `genre:video_game` parent and therefore files as a game — a genuinely
-- dual franchise, and if it should read as anime the fix is a stated
-- medium on the concept (Wikidata instance-of, the `slice` import
-- precedent), never another priority flip. Musicals are untouched.
--
-- Read-time only, like 0453: no state moves and nothing re-scores.

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
        -- 0455: a direct parent from the games world says what the work
        -- is, before the anime block may claim it. The parent's hub is
        -- the detector, so a game genre minted later is caught without a
        -- name list.
        when exists (select 1 from ontology.concept_edges e
                      join ontology.concepts p on p.id = e.object_concept_id
                     where e.subject_concept_id = target_concept_id
                       and e.ontology_version_id = target_version_id
                       and e.predicate_key = 'broader'
                       and e.status = 'active'
                       and (p.concept_key = 'hub:games_play'
                            or semantic_private.concept_hub(p.id, target_version_id)
                                 = 'hub:games_play'))
          then 'game'
        -- 0453: the medium-genre block outranks the hub for the
        -- watchable families.
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
