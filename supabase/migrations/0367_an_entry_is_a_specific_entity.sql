-- 0367 — an entry is a specific entity; a parent is a card's title.
--
-- **The owner, 2026-08-25: "each entry should be a specific person,
-- organization, group (a channel represented by more than one person is
-- also a group), work, or franchise. The parental terms that were created
-- to summarize multiple terms should be used as the title for a new card
-- with its son and daughter terms."**
--
-- The rows narrow to kinds `creator` and `work` (a franchise mints under
-- the work prefix by 0337's convention). The genre, culture, topic and
-- activity terms 0360 admitted as rows leave them again — assertions,
-- weights and cutoff stand; they appear as the headings the block
-- machinery already draws. A declared or kept term survives whatever its
-- kind.
--
-- **And the display honours nativeness, which is the contract's own rule**
-- ("the native name is the language the entity belongs to, not the script
-- this title used"). A natively English entity reads as its English name
-- alone — the owner's adjudication of 洛基: Loki is Disney's, so it is
-- "Loki", never "Loki (洛基)". A foreign entity keeps the designated pair.
-- One dictionary row is corrected below for exactly that rule: the Loki
-- keep stored the Chinese surface as its original, which the corpus rule
-- named as wrong when it was written.

begin;

-- The one-row correction the adjudication licenses: an MCU character is
-- natively English, so its original IS its english. Cited, bounded, and
-- zero rows on a clean database.
update semantic_private.presumed_terms
   set original_label = english_label
 where english_label = 'Loki'
   and original_label = '洛基';

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
    case
      -- 0367: natively English — the dictionary's original IS the english
      -- (Loki/Loki) — reads as the english alone, whatever script the
      -- concept's own label happens to be in. 洛基 is a surface, not a name.
      when native.english_label is not null
           and native.english_label !~ '[^\x00-\x7F]'
           and native.original_label = native.english_label
      then native.english_label
      -- A foreign original beside a foreign-scripted preferred label:
      -- english leads, the original follows — Sword Art Online
      -- (ソードアート・オンライン).
      when coalesce(revision.preferred_label, user_term.label) ~ '[^\x00-\x7F]'
           and native.english_label is not null
           and native.english_label !~ '[^\x00-\x7F]'
           and native.original_label ~ '[^\x00-\x7F]'
           and native.english_label <> coalesce(revision.preferred_label, user_term.label)
      then native.english_label || ' ('
             || coalesce(revision.preferred_label, user_term.label) || ')'
      -- 0365's case: an English-named concept with a genuinely foreign
      -- original appends it — Jay Chou (周杰倫); a same-script echo never
      -- composes.
      when native.original_label is not null
           and native.original_label ~ '[^\x00-\x7F]'
           and native.original_label <> coalesce(revision.preferred_label, user_term.label)
      then coalesce(revision.preferred_label, user_term.label)
             || ' (' || native.original_label || ')'
      else coalesce(revision.preferred_label, user_term.label)
    end,
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
  -- 0367: both halves of the term's identity, from the dictionary. The
  -- contract's rule decides what is drawn: the original is the language the
  -- entity *belongs to*, not the script a title used — so a natively
  -- English entity's row has original = english and earns no parenthesis,
  -- while a foreign entity's original differs and is shown. Matched by
  -- promotion link, by identity (a concept whose preferred label IS the
  -- original), or by exact label.
  left join lateral (
    select t.original_label, t.english_label
      from semantic_private.presumed_terms t
     where t.original_label is not null
       and t.english_label is not null
       and (t.promoted_concept_id = assertion.concept_id
            or t.original_label = coalesce(revision.preferred_label, '')
            or exists (
              select 1 from ontology.concept_labels l
               where l.concept_id = assertion.concept_id
                 and l.status = 'active'
                 and l.ontology_version_id = coalesce(
                       score.ontology_version_id,
                       assertion.created_ontology_version_id)
                 and l.normalized_label = t.normalized_label))
     order by (t.original_label = coalesce(revision.preferred_label, '')) desc,
              (t.promoted_concept_id = assertion.concept_id) desc,
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
    -- 0367: an entry is a specific entity — a person, an organization, a
    -- group (a channel represented by more than one person is a group), a
    -- work, or a franchise (owner, 2026-08-25). The summarizing parents —
    -- genres, subjects, cultures — are the cards' *titles*, drawn by the
    -- block machinery, never rows beside their own children. A term the
    -- person typed or kept stays theirs to see whatever its kind.
    and (
      assertion.user_term_id is not null
      or assertion.assertion_origin <> 'inferred'
      or (
        revision.concept_kind in ('creator', 'work')
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
    raise exception '0367: list_assertions lost its ordering';
  end if;
end;
$$;

commit;
