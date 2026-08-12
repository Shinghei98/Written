-- 0108 — Memories shows things a person can name, not classifications.
--
-- **The owner's reading, on their own card:** *"these blanket terms serve
-- purpose for our internal processing, but it serves no purpose for user edit.
-- The terms shown should be well defined enough for user to strike off or
-- understand — either artist/celebrities like Shiina Ringo, like ABBA; or
-- franchise like Re:Zero, Footloose."*
--
-- That is right, and this page already knew it. CLAUDE.md says of the legacy
-- Memories cards: *"every term is the source's own string… nothing on that page
-- is a word this app invented"*, and of discovery cards: *"subjects only —
-- artist and channel names, things a sentence can be about"*. `sphere:anglophone`
-- is a word this app invented, and `1990s English-language` is not something
-- anybody would say about themselves.
--
-- **Striking one off is the sharper half.** Removing "Sheena Ringo" is a
-- statement somebody can mean. Removing "English-language music" is a blunt
-- instrument whose consequences they cannot see: it is an axis the scorer
-- reasons with rather than a claim about them, and a suppression on it would
-- quietly change how everything else is weighed.
--
-- **Filtered by `concept_kind`, which is the modelled property**, not by a
-- `concept_key` prefix, which is a naming convention. It separates exactly where
-- the owner drew the line: `creator` (33 of theirs — Sheena Ringo, ABBA, Bach),
-- `work` (Re:Zero, Footloose), `activity` (sports and hobbies, none asserted
-- yet); against `genre` (13), `topic` (16 scenes and spheres) and `hub`.
--
-- **An allowlist, so a new kind is withheld until somebody decides it belongs.**
-- The same shape as the Calendar classifier's — an event is excluded unless
-- positively recognised — and for the same reason: a new internal kind
-- appearing on somebody's profile is a worse failure than a new nameable one
-- being missed, because only the first is invisible to whoever added it.
--
-- **Only this surface.** `list_assertions` is Memories' own RPC — it already
-- hardcodes `'memories'` in its guard and its suppression check — so the
-- genres, spheres and scenes keep working for matching and the icebreaker
-- exactly as before. They are withheld from a page, not from the pipeline.
--
-- **A user's own term always survives the filter.** Somebody who typed a word
-- has by definition named something they understand, and it has no concept and
-- so no kind. The filter would have removed every one of them.

begin;

create or replace function api.list_assertions()
returns table (
  assertion_id uuid, predicate_key text, label text, origin text,
  display_state text, strength double precision, confidence double precision,
  breadth integer, stability double precision, surfacing_score double precision,
  display_payload jsonb, assertion_score_version_id uuid, ontology_version_id uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    coalesce(revision.preferred_label, user_term.label),
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, assertion.created_ontology_version_id)
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
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    -- Nameable things only. A term the person typed has no concept and no kind,
    -- and is always theirs to see.
    and (
      assertion.user_term_id is not null
      or revision.concept_kind in ('creator', 'work', 'activity')
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
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$$;

do $$
declare
  columns integer;
begin
  -- The three properties this function has now lost once each: its column
  -- count, its ordering, and its guard. `0102` broke the second while checking
  -- the first, so all three are asserted together every time it is replaced.
  select count(*) into columns
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace,
       lateral unnest(coalesce(p.proargmodes, array[]::"char"[])) as mode
  where n.nspname = 'api' and p.proname = 'list_assertions' and mode = 't';
  if columns <> 13 then
    raise exception 'list_assertions returns % columns, expected 13', columns;
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) like '%order by coalesce(score.surfacing_score%'
  ) then
    raise exception 'list_assertions has no ordering';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) like '%assert_surface_allowed%'
  ) then
    raise exception 'list_assertions lost its surface guard';
  end if;

  -- And the new one, stated as the property rather than as the text: a user's
  -- own term must never be filtered out by a rule about concept kinds.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) like '%assertion.user_term_id is not null%'
  ) then
    raise exception 'the kind filter would remove user-added terms';
  end if;
end
$$;

commit;
