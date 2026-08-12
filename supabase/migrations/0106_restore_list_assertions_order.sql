-- 0106 — `list_assertions` lost its ordering in `0102`.
--
-- **Rewriting the function to add a guard dropped its last line.** `0102`
-- converted `api.list_assertions` from `language sql` to `plpgsql` so a flag
-- check could go in front of the query, pasting the body from
-- `pg_get_functiondef` — and the `order by coalesce(score.surfacing_score, 1.0)
-- desc, assertion.created_at` did not come with it.
--
-- Its own assertion checked that the function still returned thirteen columns.
-- **It did not check the one thing a rewrite of a reader most obviously breaks**,
-- which the comment beside it had already named: *"rewriting a thirteen-column
-- reader by hand is how a column silently changes position"*. Order is the same
-- hazard one step over, and counting columns cannot see it.
--
-- Found on a device, not in SQL. `-probe-surface` returned all 65 assertions
-- with `creator:fritz_kreisler` at 0.503 first, while the same query run
-- directly puts `genre:classical` at 0.963 there. Without an ordering the
-- planner returns whatever the join produces, which is stable enough to look
-- deliberate and has nothing to do with what matters about somebody.
--
-- **This is not cosmetic for this surface.** Memories draws in the order it is
-- given, so an unordered read shows a person their fourteenth-strongest trait
-- first and calls it what they are most about.

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
  -- **The line `0102` dropped.** A person's strongest trait first, and
  -- `created_at` breaks ties so two equal scores do not swap between reads —
  -- `Array.sort` is not stable in Swift either, and this project has paid for
  -- an unstable order once already in the chat's unread band.
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$$;

do $$
declare
  columns integer;
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) like '%order by coalesce(score.surfacing_score%'
  ) then
    raise exception 'list_assertions has no ordering';
  end if;

  -- Both properties, since the point of this migration is that checking one of
  -- them was not enough.
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
       and pg_get_functiondef(p.oid) like '%assert_surface_allowed%'
  ) then
    raise exception 'list_assertions lost its surface guard';
  end if;
end
$$;

commit;
