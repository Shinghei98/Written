-- 0461 — a film song's video is not a film.
--
-- **The phrase this repairs**: "Tareefan is the greatest movie in the
-- world" — about a song. YouTube stamps the topic `Film` on music videos
-- of songs that come from films, so the evidence rule of 0456 read a
-- Bollywood single as a watched movie. The discriminator is stated by
-- the source itself: a film-song video carries `Film` AND `Music`
-- together, a video about the film carries `Film` alone — so `Film` and
-- `Television_program` now count only from observations that do not also
-- state `Music`.
--
-- **What was tried and refused, so it is not tried again.** A `recording`
-- verdict for purely-musical evidence swallowed the musicals — a cast
-- recording IS how a musical is listened to, and the owner's rule says
-- OST engagement names the watchable. A name test (performed-recording
-- sightings) would strip Twilight and Cloud Atlas, whose theme songs
-- share their names. A both-parents test (learned film + learned music
-- genre) catches Mulan, Om Shanti Om and Yue Lao "(2021 film)" — real
-- films with listened OSTs. Song-versus-film is an identity fact this
-- corpus cannot derive at the name level; it needs the stated medium on
-- the concept (a Wikidata instance-of import, 0198's pattern), and until
-- then Tareefan's fossil `action_film` parent stands as a known defect
-- rather than a rule fitted to one row.

begin;

create or replace function semantic_private.work_medium_from_evidence(
  p_user_id uuid, p_concept_id uuid)
 returns text
 language sql
 stable
 set search_path to ''
as $function$
  with stated as (
    select o.id as observation_id, 'genre' as channel, g.value as word
      from semantic_private.user_term_candidates tc
      join semantic_private.candidate_support_links l
        on l.candidate_id = tc.id and l.user_id = tc.user_id
      join semantic_private.observations o on o.id = l.observation_id
      cross join lateral jsonb_array_elements_text(
        case when jsonb_typeof(o.normalized_payload -> 'genres') = 'array'
             then o.normalized_payload -> 'genres' else '[]'::jsonb end) g
     where tc.user_id = p_user_id and tc.concept_id = p_concept_id
    union all
    select o.id, 'topic', t.value
      from semantic_private.user_term_candidates tc
      join semantic_private.candidate_support_links l
        on l.candidate_id = tc.id and l.user_id = tc.user_id
      join semantic_private.observations o on o.id = l.observation_id
      cross join lateral jsonb_array_elements_text(
        case when jsonb_typeof(o.normalized_payload -> 'topics') = 'array'
             then o.normalized_payload -> 'topics' else '[]'::jsonb end) t
     where tc.user_id = p_user_id and tc.concept_id = p_concept_id
  )
  select case
    when exists (select 1 from stated where word = 'Anime') then 'anime'
    -- 0461: a film-song's video states Film AND Music together; a video
    -- about the film itself states Film without Music. Only the second
    -- is evidence of watching.
    when exists (select 1 from stated s
                  where s.word in ('Film', 'Television_program')
                    and not exists (select 1 from stated m
                                     where m.observation_id = s.observation_id
                                       and m.word in ('Music', 'Soundtrack'))) then 'film'
    when exists (select 1 from stated
                  where word in ('Video Game', 'Video Games', 'Games')
                     or word ~ '_game$' or word ~ '_video_game'
                     or word like 'Video_game%') then 'game'
    else null
  end;
$function$;

CREATE OR REPLACE FUNCTION semantic_private.matching_terms(p_subject uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(term order by term ->> 'score' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'label', coalesce(revision.preferred_label, user_term.label),
               'kind', revision.concept_kind,
               'score', coalesce(score.surfacing_score, 1.0),
               'category', case
                 when revision.concept_kind = 'work' then coalesce(
                   case semantic_private.work_medium_from_evidence(
                          assertion.user_id, assertion.concept_id)
                     when 'anime' then 'tv_series'
                     when 'film'  then 'movie'
                     when 'game'  then 'game'
                   end,
                   semantic_private.bio_category(
                     assertion.concept_id, climb.v, revision.concept_kind,
                     assertion.predicate_key, climb.blk, climb.hub))
                 else semantic_private.bio_category(
                   assertion.concept_id, climb.v, revision.concept_kind,
                   assertion.predicate_key, climb.blk, climb.hub)
               end,
               'hub', climb.hub,
               'block', climb.blk
             ) as term
        from semantic_private.user_assertions as assertion
        left join semantic_private.user_terms as user_term
          on user_term.id = assertion.user_term_id
         and user_term.user_id = assertion.user_id
        left join semantic_private.assertion_preferences as preference
          on preference.assertion_id = assertion.id
         and preference.user_id = assertion.user_id
        left join semantic_private.assertion_current_scores as current_score
          on current_score.assertion_id = assertion.id
         and current_score.user_id = assertion.user_id
        left join semantic_private.assertion_score_versions as score
          on score.id = current_score.assertion_score_version_id
         and score.user_id = current_score.user_id
         and score.assertion_id = current_score.assertion_id
        left join ontology.concept_revisions as revision
          on revision.ontology_version_id = coalesce(
               score.ontology_version_id, assertion.created_ontology_version_id
             )
         and revision.concept_id = assertion.concept_id
        cross join lateral (
          select v.v,
                 case when assertion.concept_id is null then null
                      else semantic_private.concept_block(assertion.concept_id, v.v)
                 end as blk,
                 case when assertion.concept_id is null then null
                      else semantic_private.concept_hub(assertion.concept_id, v.v)
                 end as hub
            from (select coalesce(score.ontology_version_id,
                                  assertion.created_ontology_version_id) as v) v
        ) as climb
       where assertion.user_id = p_subject
         and assertion.machine_state = 'eligible'
         and coalesce(preference.display_state, 'default') <> 'suppressed'
         and not exists (
           select 1 from semantic_private.user_suppressions as suppression
            where suppression.user_id = assertion.user_id
              and suppression.predicate_key = assertion.predicate_key
              and suppression.surface in ('matching', 'bio')
              and suppression.active
              and (
                (assertion.concept_id is not null
                 and suppression.concept_id = assertion.concept_id)
                or (assertion.user_term_id is not null
                    and suppression.user_term_id = assertion.user_term_id)
              )
         )
         -- The witness, for exactly the terms approval does not cover:
         -- confirmed is the user's own witness; declared never needed
         -- one; a travel: concept's only possible source is the
         -- calendar, a non-video source by construction; an unconfirmed
         -- inferred term of any other shape still may not cross on
         -- video evidence alone.
         and (
           assertion.assertion_origin <> 'inferred'
           or assertion.concept_id is null
           or coalesce(preference.display_state, 'default') = 'confirmed'
           or exists (select 1 from ontology.concepts travel_concept
                       where travel_concept.id = assertion.concept_id
                         and travel_concept.concept_key like 'travel:%')
           or (current_score.semantic_run_id is not null
               and semantic_private.concept_has_non_video_witness(
                     current_score.semantic_run_id, assertion.concept_id))
         )
         -- 0457: the rollup dimensions cross to nobody. `list_assertions`
         -- withholds the `era:`, `sphere:` and `scene:` prefixes from the
         -- owner's own Memories page — "withheld until somebody decides it
         -- belongs" — and the matching surface may not be more permissive
         -- than the page that shows a person their own terms. A user's own
         -- typed term has no concept and survives, as it does there.
         and (assertion.concept_id is null or not exists (
           select 1 from ontology.concepts rollup_concept
            where rollup_concept.id = assertion.concept_id
              and (rollup_concept.concept_key like 'era:%'
                   or rollup_concept.concept_key like 'sphere:%'
                   or rollup_concept.concept_key like 'scene:%')))
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$function$;

commit;
