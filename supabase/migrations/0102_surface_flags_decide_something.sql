-- 0102 — the seven feature flags decide something.
--
-- **They have decided nothing since `0048` created them.** All seven sit
-- `false` while ingestion, classification, resolution and scoring all run;
-- `flag_enabled_v031` and `api.feature_flags()` exist and have **zero callers**
-- in `aws/`, `Written/` or `supabase/functions/`. `emergency_privacy_kill_switch`
-- describes itself as *"a master stop… so a privacy incident does not wait on
-- an app release"* and stops nothing at all.
--
-- **§9's rollback contract rests on exactly this** — *"a runtime feature flag
-- can return the app to legacy non-semantic product operation while the new
-- private data remains"* — so today that sentence is false. It has not
-- mattered because nothing in the app reads any of it. **Phase 3 is where it
-- starts mattering**, being the first phase with a product surface to roll
-- back, and closing it costs one migration now against a client dependency
-- later.
--
-- **The guard already exists and was half of one.**
-- `semantic_private.assert_surface_allowed(surface_name)` is called by five of
-- the seven `api` functions and checks only that the surface is one of the four
-- names. A surface whose flag is off *is not allowed*, so this is that same
-- question rather than a second one — extending it beats adding a parallel
-- guard the five callers would each have to remember, which is how two checks
-- that must agree stop agreeing.
--
-- **`immutable` → `stable`, and that is forced.** A flag lookup reads tables,
-- so the old marking was already a promise the new body cannot keep — and an
-- `immutable` function may be folded at plan time, which for a guard means
-- evaluated once and never again.
--
-- **The kill switch comes free.** `flag_enabled_v031` already answers false for
-- every other key while `emergency_privacy_kill_switch` is enabled, so one call
-- gives both the per-surface flag and the master stop.

begin;

create or replace function semantic_private.assert_surface_allowed(surface_name text)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  required_flag text;
begin
  if surface_name is null or surface_name not in (
    'memories', 'matching', 'bio', 'icebreaker'
  ) then
    raise exception 'unsupported assertion surface';
  end if;

  -- **`bio` shares `discovery_profile_reads` with `matching`, deliberately.**
  -- A dynamic bio is a projection of one person shown to another, which is the
  -- same exposure `matching` is, and giving it a flag of its own would let the
  -- two be switched independently when the privacy question is single.
  required_flag := case surface_name
    when 'memories' then 'memories_reads'
    when 'matching' then 'discovery_profile_reads'
    when 'bio' then 'discovery_profile_reads'
    when 'icebreaker' then 'icebreaker_first_exposure'
  end;

  if not semantic_private.flag_enabled_v031(required_flag, (select auth.uid())) then
    -- Named in the message, because the first question on seeing this is which
    -- switch — and the second is whether the kill switch is down, which this
    -- same refusal covers without saying so.
    raise exception 'surface % is disabled (%)', surface_name, required_flag
      using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- **`list_assertions` is the read and called the guard from nowhere**, which is
-- the half that mattered most: a flag that stops writes and not reads is not a
-- rollback. It was `language sql`, with no statement position to put a guard in
-- — and putting one in the `where` clause would have made a disabled surface
-- return *no rows* rather than refuse, which reads as "you have no assertions".
--
-- So it becomes `plpgsql` with the guard first and the identical query after.
-- The body below is `pg_get_functiondef`'s, pasted unchanged; the column list
-- is asserted after this transaction rather than trusted.
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
    );
end;
$$;

do $$
declare
  ungated text;
  columns integer;
begin
  -- **Every `api` function that touches an assertion must reach the guard**,
  -- and `feature_flags` is the one exemption by construction: it is how a client
  -- asks which surfaces are on, so gating it behind a surface would make the
  -- answer unobtainable exactly when it is needed.
  -- **`offset 0` is an optimisation fence and it is load-bearing.**
  -- `pg_get_functiondef` *raises* on an aggregate — "array_agg is an aggregate
  -- function" — and Postgres does not promise to evaluate `where` clauses in
  -- the order they are written. Flattened, the planner is free to call it on
  -- every row of `pg_proc` before the `nspname` filter narrows to `api`, and
  -- then the migration dies on a catalog function it was never asking about.
  -- It worked in production by the luck of one plan and failed the first time
  -- the chain was replayed against an empty database, which is the same shape
  -- of accident either way. `prokind = 'f'` excludes aggregates and window
  -- functions from the answer; the fence is what stops them being touched.
  select string_agg(f.proname, ', ' order by f.proname) into ungated
  from (
    select p.proname, p.oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
      and p.prokind = 'f'
      and p.proname <> 'feature_flags'
    offset 0
  ) f
  where pg_get_functiondef(f.oid) not like '%assert_surface_allowed%';
  if ungated is not null then
    raise exception 'these api functions reach no surface guard: %', ungated;
  end if;

  -- And the guard genuinely reads a flag now, rather than only validating a
  -- name — the property that was missing and that its name always implied.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'semantic_private' and p.proname = 'assert_surface_allowed'
       and pg_get_functiondef(p.oid) like '%flag_enabled_v031%'
  ) then
    raise exception 'assert_surface_allowed does not consult the flags';
  end if;

  -- `list_assertions` kept its shape. Rewriting a thirteen-column reader by
  -- hand is how a column silently changes position, and every caller reads by
  -- position over the wire.
  --
  -- **Counted from `proargmodes`, not `information_schema.columns`.** A
  -- set-returning function has no entry there, so the first version of this
  -- check answered 0 for a perfectly good function — and had the expectation
  -- been written as `>= 0` rather than `= 13`, it would have passed while
  -- measuring nothing. `t` is a table-mode output column.
  select count(*) into columns
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace,
       lateral unnest(coalesce(p.proargmodes, array[]::"char"[])) as mode
  where n.nspname = 'api' and p.proname = 'list_assertions' and mode = 't';
  if columns <> 13 then
    raise exception 'list_assertions returns % columns, expected 13', columns;
  end if;
end
$$;

commit;
