-- 0164 — the dyad producer: a bridge both people reach, and a term either side.
--
-- **Every table this writes has existed since `0046` and nothing has ever
-- written one.** `dyad_runs`, `dyad_alignment_pairs`, four guards and an active
-- `dyad_ranker` model, all at zero rows — the same shape as the itinerary rule,
-- built and never called. This is the caller.
--
-- ## What a dyad is
--
-- For an authorised pair it finds **bridges**: concepts both people reach, by
-- their own assertions or by walking `broader` up from them. The bridge is what
-- they share; the two assertions either side of it are what each of them
-- specifically has. That is the owner's sentence — *"you both like anime, Timi
-- is obsessed with One Piece"* — with the bridge as the first clause and the
-- subject's own term as the second.
--
-- The block graph is the bridge graph. A block *is* a candidate bridge, which is
-- why the `broader` edges authored in `0154` and `0162` matter here: members
-- reaching their genre is what lets two people bridge on K-Pop while holding
-- different idols underneath.
--
-- ## What the guards demand, and why the match had to exist first
--
-- `guard_dyad_run_current` refuses any run whose revisions are not *both*
-- current and whose `active_match_authorization_id_v031(viewer, subject)` is
-- null — and a conversation is what makes that non-null. So no dyad can be
-- computed for two people who have not matched, structurally rather than by a
-- check somebody has to remember.
--
-- `guard_dyad_data_use_purpose` refuses a `general_social` run holding any pair
-- whose assertion carries HealthKit evidence. This producer is `general_social`,
-- so it excludes those assertions at selection rather than discovering the
-- refusal at insert — the guard stays as the backstop it is meant to be.
--
-- ## The numbers, and which of them are provisional
--
-- `specificity` and `information_value` are the columns that should rank *One
-- Piece* above *anime*, and the spec records that nothing computed them. Here
-- they are, and both are deliberately simple and openly provisional:
--
--   specificity        1 / (1 + mean hops to the bridge). A bridge one hop from
--                      both terms is specific; four hops up is `hub:music`,
--                      which is true of anybody with a library.
--   information_value  1 / (1 + direct children of the bridge). A container
--                      with thirteen children says almost nothing when shared —
--                      the `genre:asian_music` problem, a concept at 0.942 that
--                      is a container in all but name.
--
-- Neither is the real answer. The real answer is how *rare* a bridge is across
-- the population, which needs a population; these are stand-ins that already
-- rank a genre above a hub, and they are named in the model parameters so a
-- later reader knows which numbers were guesses.
--
-- `embedding_distance` is 1.0 throughout, and that is not a measurement: there
-- is no embedding model in `ontology.model_versions`, so the column is at its
-- bound rather than carrying a distance nobody computed. The check constraint
-- requires `[0,1]` and offers no way to say "unknown", which is worth knowing
-- before anybody reads a mean of it.
--
-- ## An empty result is a result
--
-- Measured on the first authorised pair: David has 99 eligible assertions, Timi
-- has 0, and their direct overlap is 0 — her Spotify has never reached the
-- vault. So the first real dyad produces a run with no pairs, and that must be a
-- `succeeded` run with `coverage_overlap` 0 rather than a failure. A pair with
-- nothing in common is an ordinary outcome and the product has to say so.

begin;

create or replace function semantic_private.produce_dyad(
  p_viewer uuid, p_subject uuid, p_purpose text default 'icebreaker'
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  run_id uuid;
  version_id uuid;
  ranker_id uuid;
  viewer_rev bigint;
  subject_rev bigint;
  started timestamptz := clock_timestamp();
  pairs integer := 0;
  viewer_terms integer := 0;
  subject_terms integer := 0;
begin
  select id into version_id from ontology.versions where status = 'published';
  select id into ranker_id from ontology.model_versions
   where model_role = 'dyad_ranker' and status = 'active'
   order by created_at desc limit 1;
  if version_id is null or ranker_id is null then
    raise exception 'no published ontology version or active dyad ranker';
  end if;

  select coalesce(revision, 0) into viewer_rev
    from semantic_private.user_state_versions where user_id = p_viewer;
  select coalesce(revision, 0) into subject_rev
    from semantic_private.user_state_versions where user_id = p_subject;
  viewer_rev := coalesce(viewer_rev, 0);
  subject_rev := coalesce(subject_rev, 0);

  -- The guard refuses this insert unless both revisions are current and the two
  -- are an authorised match. Nothing here checks that a second time: one
  -- statement of a rule is better than two that can disagree.
  insert into semantic_private.dyad_runs (
    viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, input_hash, status,
    data_use_purpose
  ) values (
    p_viewer, p_subject, viewer_rev, subject_rev, version_id, ranker_id,
    p_purpose,
    -- `sha256` is a built-in; `digest` is pgcrypto, which lives in
    -- `extensions` and is unreachable under `search_path to ''`.
    encode(sha256(convert_to(
      p_viewer::text || ':' || p_subject::text || ':' ||
      viewer_rev::text || ':' || subject_rev::text || ':' ||
      version_id::text, 'UTF8')), 'hex'),
    'running', 'general_social'
  ) returning id into run_id;

  -- **Each side's terms, and their ancestors.** `broader` is a DAG, so a term
  -- reaches several ancestors and a bridge may be any of them. Four hops is the
  -- cap: beyond that everything meets at a hub, which is true of everybody and
  -- therefore says nothing.
  --
  -- HealthKit-evidenced assertions are excluded here rather than filtered at
  -- insert, because `guard_dyad_data_use_purpose` refuses the whole run for one
  -- such pair and a backstop should not be the thing that finds the problem.
  create temporary table dyad_side on commit drop as
  with recursive term as (
    select a.user_id, a.id as assertion_id, a.concept_id,
           coalesce(sv.surfacing_score, 0.5) as score
    from semantic_private.user_assertions a
    left join semantic_private.assertion_current_scores cs
      on cs.assertion_id = a.id and cs.user_id = a.user_id
    left join semantic_private.assertion_score_versions sv
      on sv.id = cs.assertion_score_version_id
    where a.user_id in (p_viewer, p_subject)
      and a.machine_state = 'eligible'
      and a.concept_id is not null
      and not semantic_private.assertion_has_healthkit_evidence(a.id, a.user_id)
  ),
  climb (user_id, assertion_id, concept_id, score, node_id, hops) as (
    select t.user_id, t.assertion_id, t.concept_id, t.score, t.concept_id, 0
    from term t
    union all
    select c.user_id, c.assertion_id, c.concept_id, c.score,
           e.object_concept_id, c.hops + 1
    from climb c
    join ontology.concept_edges e
      on e.subject_concept_id = c.node_id
     and e.predicate_key = 'broader'
     and e.ontology_version_id = version_id
     and e.status = 'active'
    where c.hops < 4
  )
  select * from climb;

  select count(distinct assertion_id) into viewer_terms from dyad_side where user_id = p_viewer;
  select count(distinct assertion_id) into subject_terms from dyad_side where user_id = p_subject;

  -- One pair per bridge: each side's strongest term beneath it.
  insert into semantic_private.dyad_alignment_pairs (
    dyad_run_id, viewer_user_id, subject_user_id,
    viewer_assertion_id, subject_assertion_id, bridge_concept_id,
    ontology_version_id, graph_distance, relation_distance, embedding_distance,
    transport_mass, specificity, information_value, explanation_path
  )
  select
    run_id, p_viewer, p_subject, v.assertion_id, s.assertion_id, v.node_id,
    version_id,
    least(1.0, (v.hops + s.hops)::float8 / 8.0),
    least(1.0, (v.hops + s.hops)::float8 / 8.0),
    -- No embedding model exists; this is the bound, not a distance.
    1.0,
    greatest(0.001, least(1.0, v.score * s.score)),
    1.0 / (1.0 + ((v.hops + s.hops)::float8 / 2.0)),
    1.0 / (1.0 + (
      select count(*) from ontology.concept_edges child
      where child.object_concept_id = v.node_id
        and child.predicate_key = 'broader'
        and child.ontology_version_id = version_id
        and child.status = 'active'
    )),
    jsonb_build_object(
      'path_type', 'broader_ancestor',
      'predicate_path', jsonb_build_array('broader'),
      'concept_path', jsonb_build_array(
        (select concept_key from ontology.concepts where id = v.concept_id),
        (select concept_key from ontology.concepts where id = v.node_id),
        (select concept_key from ontology.concepts where id = s.concept_id)
      ),
      'cost_components', jsonb_build_object(
        'viewer_hops', v.hops, 'subject_hops', s.hops
      )
    )
  from (
    select distinct on (node_id) node_id, assertion_id, concept_id, score, hops
    from dyad_side where user_id = p_viewer
    order by node_id, score desc, hops
  ) v
  join (
    select distinct on (node_id) node_id, assertion_id, concept_id, score, hops
    from dyad_side where user_id = p_subject
    order by node_id, score desc, hops
  ) s on s.node_id = v.node_id;

  get diagnostics pairs = row_count;

  update semantic_private.dyad_runs
     set status = 'succeeded',
         finished_at = now(),
         semantic_proximity = case when pairs = 0 then 0.0
           else least(1.0, pairs::float8 / greatest(1, least(viewer_terms, subject_terms))) end,
         comparability = case when least(viewer_terms, subject_terms) = 0 then 0.0 else 1.0 end,
         metrics = jsonb_build_object(
           'coverage_overlap', pairs,
           'duration_ms', round(extract(milliseconds from clock_timestamp() - started))
         )
   where id = run_id;

  return run_id;
end;
$function$;

revoke all on function semantic_private.produce_dyad(uuid, uuid, text) from public;
revoke all on function semantic_private.produce_dyad(uuid, uuid, text) from anon;
revoke all on function semantic_private.produce_dyad(uuid, uuid, text) from authenticated;

do $$
declare
  granted boolean;
begin
  -- **No client role may call this.** A dyad is computed about two people from
  -- both their private assertions; it is worker work, and `0124`'s lesson is
  -- that Supabase grants every new function to anon and authenticated by
  -- default and `revoke ... from public` leaves those grants untouched.
  select has_function_privilege('anon', 'semantic_private.produce_dyad(uuid,uuid,text)', 'execute')
    into granted;
  if granted then raise exception 'anon can execute produce_dyad'; end if;
  select has_function_privilege('authenticated', 'semantic_private.produce_dyad(uuid,uuid,text)', 'execute')
    into granted;
  if granted then raise exception 'authenticated can execute produce_dyad'; end if;

  raise notice '0164: produce_dyad is worker-only';
end;
$$;

commit;
