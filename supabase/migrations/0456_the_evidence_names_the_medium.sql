-- 0456 — the evidence names the medium, per user.
--
-- **The owner's rule (2026-08-28), and it is the watching-against-doing
-- precedent applied to franchises.** A franchise spanning game and
-- watchable media (Sword Art Online, Persona, Final Fantasy) cannot be
-- given one medium on the concept, because the medium is a fact about
-- the *user's engagement*, not the franchise: listening to the anime's
-- OST makes it an anime for that person; listening to the game's OST
-- makes it a game; watching videos about the anime prioritizes anime —
-- the same shape as `participates_in_activity` against
-- `follows_activity`, where the evidence decides and the concept only
-- accumulates.
--
-- **The signal is stated by the source, never inferred.** Apple Music
-- stamps `Anime` on an anime OST and `Video Game` on a game OST — the
-- measured rows behind this migration: SAO's "Courage" states
-- ["Anime","Music","J-Pop"], Persona 5's "Last Surprise" states
-- ["Video Game","Music","Soundtrack"]. YouTube states topic slugs the
-- same way. Reading them is the same act as the genre rollup's
-- provider_metadata read. Spotify states no genres on these payloads,
-- so Spotify-only evidence falls through to 0455's stated-parent rule —
-- a fallback, never a guess.
--
-- Priority on mixed evidence: anime, then film, then game — the owner's
-- "prioritize anime". Evaluated per (user, concept) at read time in
-- `matching_terms`; the same franchise may be an anime on one person's
-- card and a game on another's, which is dynamic prompting doing its
-- job rather than an inconsistency.

begin;

create or replace function semantic_private.work_medium_from_evidence(
  p_user_id uuid, p_concept_id uuid)
 returns text
 language sql
 stable
 set search_path to ''
as $function$
  -- The user's own support observations for this concept, read through
  -- the candidate lane (which carries both the resolver's music rows and
  -- the mention lane's YouTube rows). Genres and topics are what the
  -- source stated; nothing here computes a label the source did not give.
  with stated as (
    select g.value as word
      from semantic_private.user_term_candidates tc
      join semantic_private.candidate_support_links l
        on l.candidate_id = tc.id and l.user_id = tc.user_id
      join semantic_private.observations o on o.id = l.observation_id
      cross join lateral jsonb_array_elements_text(
        case when jsonb_typeof(o.normalized_payload -> 'genres') = 'array'
             then o.normalized_payload -> 'genres' else '[]'::jsonb end) g
     where tc.user_id = p_user_id and tc.concept_id = p_concept_id
    union all
    select t.value
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
    when exists (select 1 from stated
                  where word in ('Film', 'Television_program', 'TV Soundtrack',
                                 'Original Score')) then 'film'
    when exists (select 1 from stated
                  where word in ('Video Game', 'Video Games', 'Games')
                     or word ~ '_game$' or word ~ '_video_game'
                     or word like 'Video_game%') then 'game'
    else null
  end;
$function$;

-- `matching_terms` applies the evidence verdict for work-kind terms and
-- falls back to `bio_category`'s stated-parent rule where the sources
-- said nothing. Everything else in the function is unchanged from 0443's
-- shape; the category expression is the only edit.
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
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$function$;

commit;
