-- 0464 — a genre is a line at last.
--
-- **The owner's boilerplate arrived (2026-08-28)**: "Don't judge me but
-- my playlist is all KPOP." — and per the icebreaker's rule the language
-- lives in Swift while this migration only teaches the category layer to
-- offer the ingredient: a `genre`-kind term under `hub:music` now
-- categorizes `genre` instead of `other`. Music genres only — a
-- playlist is a claim about listening, and `genre:video_game` under the
-- games hub stays silent rather than claiming one. Every other `.other`
-- resident (recordings, labels, cultures, mis-kinded works) stays off
-- the bio exactly as the owner directed.
--
-- A client that predates the template decodes the new wire value to
-- `.other` and stays silent — a server ahead of the app degrades to
-- silence, never to a wrong sentence.

begin;

CREATE OR REPLACE FUNCTION semantic_private.bio_category(target_concept_id uuid, target_version_id uuid, target_kind text, target_predicate text, block_key text, hub_key text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case
    when target_concept_id is null then 'other'
    when exists (select 1 from ontology.concepts c
                  where c.id = target_concept_id
                    and c.concept_key like 'travel:%') then 'travel'
    when target_predicate = 'participates_in_activity'
         and exists (select 1 from ontology.concepts c
                      where c.id = target_concept_id
                        and c.concept_key like 'activity:%')
      then 'sport_doing'
    -- 0464: a music genre is sayable. The playlist line is the client's;
    -- this only offers the ingredient, and only where the hub says the
    -- claim is about listening.
    when target_kind = 'genre' and hub_key = 'hub:music' then 'genre'
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
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') in ('anime', 'tv_series')
          then 'tv_series'
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') = 'film'
          then 'movie'
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') = 'game'
          then 'game'
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') = 'recording'
          then 'other'
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
        when exists (select 1 from ontology.concept_edges e
                      where e.subject_concept_id = target_concept_id
                        and e.ontology_version_id = target_version_id
                        and e.predicate_key in ('performed_by', 'composed_by')
                        and e.status = 'active'
                        and (e.provenance_type in ('curated', 'provider')
                             or (e.provenance_type = 'learned'
                                 and (e.provenance ->> 'source' = '0374_relation_promotion'
                                      or e.provenance ->> 'rule' ~ '^[0-9]{4} '))))
          then 'other'
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
