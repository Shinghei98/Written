-- 0364 — a foreign term reads as the syntax designated for it.
--
-- **The owner, 2026-08-25: "for foreign it should be official name
-- (original language name)."** The contract has said so since v19 —
-- `give_english_label_and_original_label_when_the_term_is_not_english`,
-- `original_label_is_the_entitys_own_language` — and the dictionary stores
-- both halves (`presumed_terms.english_label` / `original_label`). The
-- Memories page, though, drew `revision.preferred_label` alone, and the
-- catalogue concept often holds only the English (creator:jay_chou carries
-- no 周杰倫 label at all). So the composition happens at display, joined
-- from the one store that knows both: Jay Chou (周杰倫), YOASOBI stays
-- YOASOBI, Ariana Grande stays herself.
--
-- Same body as 0360's redefinition with exactly two additions, each marked
-- `-- 0364:`. Measured before writing: 44 of the 140 concepts on the test
-- account's page carry a distinct original-language name in the dictionary.

begin;

create or replace function api.list_assertions()
returns table(
  assertion_id uuid, predicate_key text, label text, origin text,
  display_state text, strength double precision, confidence double precision,
  breadth integer, stability double precision,
  surfacing_score double precision, display_payload jsonb,
  assertion_score_version_id uuid, ontology_version_id uuid,
  block_key text, block_label text
)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    -- 0364: the designated syntax — official name (original language
    -- name) — composed from the dictionary, which is the one store that
    -- knows both halves of a foreign term's identity.
    coalesce(revision.preferred_label, user_term.label)
      || coalesce(' (' || native.original_label || ')', ''),
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'), assertion.created_ontology_version_id),
    block.concept_key,
    block_revision.preferred_label
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  left join semantic_private.user_terms as user_term
    on user_term.id = assertion.user_term_id
   and user_term.user_id = assertion.user_id
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
  -- **The concept's own key, which the filter below needs and nothing here had.**
  -- A primary-key lookup, and `left` rather than `inner` because a user's own
  -- term has no concept at all and an inner join would delete every one of them.
  left join ontology.concepts as concept
    on concept.id = assertion.concept_id
  -- The block, and its label at the same version the term is read at, so a
  -- heading can never come from a different ontology than the row under it.
  left join lateral (
    select c.id, c.concept_key
      from ontology.concepts c
     where c.concept_key = semantic_private.concept_block(
             assertion.concept_id,
             coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                      assertion.created_ontology_version_id))
  ) as block on true
  left join ontology.concept_revisions as block_revision
    on block_revision.concept_id = block.id
   and block_revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
  -- 0360: the topical hub this row buckets under, for the cutoff. Null for
  -- a user's own term (no concept) and for a concept outside every hub.
  left join lateral (
    select semantic_private.concept_hub(
             assertion.concept_id,
             coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                      assertion.created_ontology_version_id)) as hub_key
  ) as hub on true
  -- 0364: the entity's own-language name, from `presumed_terms` — reached
  -- by the promotion link where one exists, else by exact normalized-label
  -- match at this version. Only a name that genuinely differs is shown; an
  -- English-native term keeps its single name.
  left join lateral (
    select t.original_label
      from semantic_private.presumed_terms t
     where t.original_label is not null
       and t.english_label is not null
       and t.original_label <> t.english_label
       and t.original_label <> coalesce(revision.preferred_label, '')
       and (t.promoted_concept_id = assertion.concept_id
            or exists (
              select 1 from ontology.concept_labels l
               where l.concept_id = assertion.concept_id
                 and l.status = 'active'
                 and l.ontology_version_id = coalesce(
                       score.ontology_version_id,
                       assertion.created_ontology_version_id)
                 and l.normalized_label = t.normalized_label))
     order by (t.promoted_concept_id = assertion.concept_id) desc,
              t.mention_support desc nulls last, t.id
     limit 1
  ) as native on true
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    -- Nameable things only. A term the person typed has no concept and no kind,
    -- and is always theirs to see.
    --
    -- `topic` joins the allowlist, less the three axis families: an axis is
    -- something the scorer reasons with, not a claim anybody would make about
    -- themselves, and striking one off would silently reweigh everything else.
    --
    -- 0360: `genre` and `culture` join it, and that is the owner deciding
    -- they belong (2026-08-25) — the propagated tail's whole point is that
    -- genre:pop and culture:taiwan are terms a person keeps or strikes, and
    -- an allowlist that withheld them would hide exactly what the bootstrap
    -- exists to price. The axis exclusions stand; `medium` and `hub` stay
    -- out, being structure rather than taste.
    and (
      assertion.user_term_id is not null
      or (
        revision.concept_kind in ('creator', 'work', 'activity', 'topic',
                                  'genre', 'culture')
        and concept.concept_key not like 'era:%'
        and concept.concept_key not like 'sphere:%'
        and concept.concept_key not like 'scene:%'
      )
    )
    and (
      assertion.assertion_origin <> 'inferred' or
      (
        score.id is not null
        and score_run.status = 'succeeded'
        and score_run.input_revision = coalesce(user_state.revision, 0)
      )
    )
    and not exists (
      select 1
      from semantic_private.user_suppressions as suppression
      where suppression.user_id = assertion.user_id
        and suppression.predicate_key = assertion.predicate_key
        and suppression.surface = 'memories'
        and suppression.active
        and (
          (assertion.concept_id is not null and suppression.concept_id = assertion.concept_id) or
          (assertion.user_term_id is not null and suppression.user_term_id = assertion.user_term_id)
        )
    )
    -- 0360: the cutoff. A display decision, per (user, hub), from the one
    -- active release. `coalesce(..., 1.0)` is deliberate twice over: a
    -- declared term has no score row and passes any cutoff at the top score
    -- (the same fallback the order by already uses), and a concept outside
    -- every hub resolves through the release default.
    and coalesce(score.surfacing_score, 1.0)
        >= semantic_private.active_memories_cutoff(assertion.user_id, hub.hub_key)
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$;

do $$
begin
  if position('order by coalesce(score.surfacing_score, 1.0) desc' in
       pg_get_functiondef('api.list_assertions()'::regprocedure)) = 0 then
    raise exception '0364: list_assertions lost its ordering';
  end if;
end;
$$;

commit;
