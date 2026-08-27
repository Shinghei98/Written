
-- 0443 — a kept term is the user's own prompt.
--
-- **The owner's interpretation of record (2026-08-28), for the dynamic
-- bio surface, refined to its exact form**: every term on a card was
-- first shown to its owner on Memories as a suggestion — a draft we
-- wrote — and a term the owner *confirmed* is their own statement,
-- like a prompt they wrote after we suggested the wording. What
-- somebody approved is not machine-derived data being disclosed about
-- them.
--
-- On that ruling the surface's own guards come out of `matching_terms`:
-- the `bio.can_name` permission requirement (and the calendar and
-- HealthKit source guards standing behind it) and the score-currency
-- withholding. They were ours, and the owner waived them.
--
-- **What stays, and why each line is load-bearing**:
--   * `machine_state = 'eligible'` — a candidate was never a suggestion
--     the user saw, and nothing unseen can have been approved;
--   * both suppression checks — a struck term is the one thing the user
--     explicitly did NOT approve, and the approval theory stands on the
--     strike being honored;
--   * the non-video witness test, for exactly the terms the approval
--     theory does not reach: an inferred term the user has NOT
--     confirmed is still machine-derived at the moment it crosses to a
--     stranger, and III.E.3.b is a third party's term, not ours to
--     waive. A confirmed term needs no witness — the user is the
--     witness. A declared term never did.

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
         -- confirmed is the user's own witness; declared never needed one;
         -- an unconfirmed inferred term still may not cross on video
         -- evidence alone.
         and (
           assertion.assertion_origin <> 'inferred'
           or assertion.concept_id is null
           or coalesce(preference.display_state, 'default') = 'confirmed'
           or (current_score.semantic_run_id is not null
               and semantic_private.concept_has_non_video_witness(
                     current_score.semantic_run_id, assertion.concept_id))
         )
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$$;

revoke all on function semantic_private.matching_terms(uuid)
  from public, anon, authenticated;

do $$
declare subject uuid; n integer;
begin
  select a.user_id into subject
    from semantic_private.user_assertions a
   where a.machine_state = 'eligible'
   group by a.user_id order by count(*) desc limit 1;
  if subject is not null then
    n := jsonb_array_length(semantic_private.matching_terms(subject));
    raise notice '0443: % term(s) cross for the fullest account', n;
  end if;
end;
$$;

commit;
