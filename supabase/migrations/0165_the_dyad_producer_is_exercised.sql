-- 0165 — the producer is corrected, then exercised both ways.
--
-- **`0164` shipped with `digest`, which is pgcrypto.** It lives in `extensions`
-- on this platform and the function sets `search_path to ''`, so the call
-- resolved to nothing and every run raised `function digest(text, unknown) does
-- not exist` — at runtime, not at creation, because plpgsql plans an expression
-- when it first executes. The migration applied cleanly and left a producer that
-- could not produce. `sha256` is a built-in and needs no extension.
--
-- **A rule that has only ever permitted has not been tested.** `0117` shipped a
-- predicate that answered false for everything and passed its own structural
-- check, so this calls the producer twice: once for the authorised match, and
-- once for a pair with no conversation, which must raise.
--
-- The authorised run is expected to produce **no pairs**. David has 99 eligible
-- assertions, Timi has 0 because her Spotify has never reached the vault, and
-- two people with nothing in common are an ordinary outcome rather than a
-- failure.

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

do $$
declare
  david uuid := 'eb769605-5e2c-4175-8b9d-e3864ceaafb1';
  timi uuid := '7046df73-c4ce-4c91-b3ef-2956f104bc8f';
  demo uuid := '076f08f9-b27d-4004-bd5c-ec103c3496b0';
  run_id uuid;
  run_status text;
  pair_count integer;
  refused boolean := false;
begin
  -- **Only where the pair exists.** This exercises the producer against two real
  -- accounts and a real accepted like, so on an empty database there is nothing
  -- to run it on and the migration would refuse — stopping the whole chain
  -- replaying and hiding every schema change after it, which is exactly what
  -- `0144` did until it was guarded the same way. With the data the checks are
  -- as strict as they were; without it there is no claim to be wrong about.
  if not exists (select 1 from public.conversations c
                 where (c.user_a = david and c.user_b = timi)
                    or (c.user_a = timi and c.user_b = david)) then
    raise notice '0165: no authorised pair on this database; producer unexercised';
    return;
  end if;

  -- 1. The authorised pair. Timi liked David on 2026-08-14 and he accepted, so
  --    `active_match_authorization_id_v031` is non-null and the run is allowed.
  run_id := semantic_private.produce_dyad(david, timi, 'icebreaker');

  select status into run_status from semantic_private.dyad_runs where id = run_id;
  if run_status is distinct from 'succeeded' then
    raise exception 'authorised dyad finished as % rather than succeeded', run_status;
  end if;

  select count(*) into pair_count
  from semantic_private.dyad_alignment_pairs where dyad_run_id = run_id;
  raise notice '0165: authorised dyad produced % alignment pairs', pair_count;

  -- 2. A pair with no conversation. `guard_dyad_run_current` must refuse, and
  --    the refusal is the point: without it a dyad could be computed for two
  --    people who have never matched.
  begin
    perform semantic_private.produce_dyad(david, demo, 'icebreaker');
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception 'a dyad was computed for an unauthorised pair';
  end if;

  raise notice '0165: an unauthorised pair is refused';
end;
$$;

commit;
