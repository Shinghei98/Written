-- 0442 — a term knows which sentence it belongs in.
--
-- **The dynamic bio redesign (owner, 2026-08-28), server half.** Six
-- mutual terms between viewer and card-subject become the card's
-- rotation pool, each rendered through a per-category sentence — and
-- the category is decided HERE, where the signals live (edges, keys,
-- blocks, hubs), so nothing but labels and closed generic vocabularies
-- ever cross the wire to a stranger. The client composes; the server
-- categorizes ("ingredients in SQL, language in Swift" — the
-- icebreaker's own rule).
--
-- `matching_terms` is replaced with every gate copied verbatim from
-- 0128 — eligible-only, not suppressed, `bio.can_name` (which survived
-- the YouTube/calendar/HealthKit grant guards), current-score currency,
-- `concept_has_non_video_witness` — and the projection widened to
-- {label, kind, score, category, hub, block}. `api.discover_profiles`
-- embeds this function, so the wire widens with no new api function,
-- no new surface gate, and no contract-debt entry.
--
-- Dormant by construction: `athlete_team` (zero athlete concepts;
-- activation is the Wikidata fan-name derivation), `author_director`
-- (no directed_by/authored_by predicate yet), `screen` (a screen work
-- whose genre key names neither film nor television — a nil-template
-- category client-side, skipped rather than mislabeled).

begin;

create or replace function semantic_private.bio_category(
  target_concept_id uuid,
  target_version_id uuid,
  target_kind text,
  target_predicate text,
  block_key text,
  hub_key text
) returns text
language sql
stable
set search_path = ''
as $function$
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

revoke all on function semantic_private.bio_category(uuid, uuid, text, text, text, text)
  from public, anon, authenticated;

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
        left join semantic_private.user_state_versions as user_state
          on user_state.user_id = assertion.user_id
        left join semantic_private.semantic_runs as score_run
          on score_run.id = current_score.semantic_run_id
         and score_run.user_id = assertion.user_id
         and score_run.status = 'succeeded'
         and score_run.input_revision = coalesce(user_state.revision, 0)
        left join semantic_private.assertion_score_versions as score
          on score.id = current_score.assertion_score_version_id
         and score.user_id = current_score.user_id
         and score.assertion_id = current_score.assertion_id
         and score.semantic_run_id = score_run.id
        left join ontology.concept_revisions as revision
          on revision.ontology_version_id = coalesce(
               score.ontology_version_id, assertion.created_ontology_version_id
             )
         and revision.concept_id = assertion.concept_id
        -- The climbs run once per term and feed the categorizer, which
        -- only does cheap probes on top of them.
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
         -- **`bio.can_name`, not `matching.can_select`.** Returning a label is
         -- naming, and only the bio surface permits it.
         and exists (
           select 1 from semantic_private.assertion_surface_permissions as permission
            where permission.assertion_id = assertion.id
              and permission.user_id = assertion.user_id
              and permission.surface = 'bio'
              and permission.can_name
         )
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
         and (
           assertion.assertion_origin <> 'inferred'
           or (score.id is not null and score_run.id is not null)
         )
         and (
           assertion.assertion_origin <> 'inferred'
           or assertion.concept_id is null
           or semantic_private.concept_has_non_video_witness(
                score_run.id, assertion.concept_id)
         )
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$$;

revoke all on function semantic_private.matching_terms(uuid)
  from public, anon, authenticated;

-- The transformation asserted, never the precondition: over whatever the
-- database holds, every emitted category is in the closed vocabulary,
-- athlete_team never fires, and no term lost its label.
do $$
declare bad integer; athletes integer; unlabeled integer; sampled integer := 0;
        subject uuid; terms jsonb;
begin
  for subject in
    select distinct a.user_id from semantic_private.user_assertions a
     where a.machine_state = 'eligible' limit 10
  loop
    terms := semantic_private.matching_terms(subject);
    sampled := sampled + jsonb_array_length(terms);
    select count(*) into bad from jsonb_array_elements(terms) t
     where t ->> 'category' is null
        or t ->> 'category' not in
          ('composer','performer','tv_series','movie','author_director',
           'book','creator','game','travel','sport_doing','athlete_team',
           'subject','subject_language','screen','other');
    if bad > 0 then
      raise exception '0442: % term(s) outside the closed category vocabulary', bad;
    end if;
    select count(*) into athletes from jsonb_array_elements(terms) t
     where t ->> 'category' = 'athlete_team';
    if athletes > 0 then
      raise exception '0442: athlete_team fired with zero athlete concepts';
    end if;
    select count(*) into unlabeled from jsonb_array_elements(terms) t
     where nullif(t ->> 'label', '') is null;
    if unlabeled > 0 then
      raise exception '0442: a term lost its label in the widening';
    end if;
  end loop;
  raise notice '0442: % term(s) sampled, all categorized in-vocabulary', sampled;
end;
$$;

commit;
