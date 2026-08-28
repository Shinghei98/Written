-- 0457 — a rollup withheld from its owner crosses to nobody.
--
-- **`matching_terms` was more permissive than Memories.** `list_assertions`
-- excludes the `era:`, `sphere:` and `scene:` prefixes — the era-by-language
-- rollup dimension ("2020s Mandarin", "Mandarin-language music") is withheld
-- from the owner's own page until somebody decides it belongs — but the bio
-- surface applied no such exclusion, so sixteen of one user's forty-seven
-- matching terms were rollups the product had decided not even to show her.
-- Harmless only while the `other` category renders nothing; the day a
-- genre/topic sentence ships, a scene rollup would become a stranger-facing
-- bio line. The exclusion mirrors Memories': prefix-keyed, and a user's own
-- typed term (no concept) survives it, as it does there.

begin;

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
