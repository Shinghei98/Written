-- 0444 — the calendar is its own witness.
--
-- **The trips still did not cross after 0443, and the reason is the
-- witness test answering the wrong question for them.**
-- `concept_has_non_video_witness` looks for an accepted non-video
-- observation mapping — but a trip assertion has no mappings at all,
-- by design: calendar rows may never enter the mapping table
-- (`guard_calendar_observation_mapping`), and `assert_travel` writes
-- its score with no evidence rows for exactly that reason. So the test
-- read "no mappings" as "no non-video witness" and withheld terms
-- whose provenance was never video in the first place. III.E.3.b's
-- rule is that video may never be the ONLY reason a term crosses; for
-- a `travel:` concept, video is not a reason at all — its only
-- possible source is the calendar, which is a non-video source by
-- construction, so the calendar is the witness.
--
-- Narrow on purpose: only `travel:` keys gain this reading. The
-- propagated field terms keep the mapping-based witness requirement —
-- they genuinely derive from YouTube channels through the edge flow,
-- and zero direct mappings does NOT make their provenance non-video.
-- Everything else in 0443 stands unchanged.

begin;

create or replace function semantic_private.matching_terms(p_subject uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(term order by term ->> 'score' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'label', coalesce(revision.preferred_label, user_term.label),
               'kind', revision.concept_kind,
               'score', coalesce(score.surfacing_score, 1.0),
               'category', semantic_private.bio_category(
                 assertion.concept_id, climb.v, revision.concept_kind,
                 assertion.predicate_key, climb.blk, climb.hub),
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
$$;

revoke all on function semantic_private.matching_terms(uuid)
  from public, anon, authenticated;

commit;
