-- 0412 — a calibration release is part of the run's identity.
--
-- **Found delivering the owner's neutrality request (2026-08-26): after
-- release-bootstrap-3 published, nothing would rescore.** Two organs
-- shared the same blindness:
--
-- 1. A run's identity was `(user, revision, ontology, resolver, scorer)`
--    — the calibration release, now a scorer input, was invisible to it,
--    so `recompute_user` answered "already resolved" and kept scores
--    computed under the retired release. Forced runs changed nothing;
--    no route could.
-- 2. `enqueue_recompute_on_analysis_change`'s candidate filter and
--    idempotency key had the same shape, so a release-only publish
--    enqueued exactly zero jobs — an analysis change with no analysis.
--
-- The repair teaches both: `semantic_runs` gains
-- `calibration_release_id` (written by the worker, which also folds the
-- release into `input_hash`, so the standing identity index
-- differentiates without being rebuilt), and the enqueue's candidate
-- filter and idempotency key both learn the active release. Ends with
-- the enqueue itself — which now, for the first time since
-- bootstrap-3 published, actually enqueues the neutral rescores.

begin;

alter table semantic_private.semantic_runs
  add column calibration_release_id uuid
    references semantic_private.calibration_releases (id);

create or replace function semantic_private.enqueue_recompute_on_analysis_change(
  p_reason text, p_user_id uuid default null)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  ontology_version_id_value uuid;
  resolver_model_id_value uuid;
  scorer_model_id_value uuid;
  embedding_model_id_value uuid;
  calibration_release_id_value uuid;
  enqueued integer := 0;
begin
  select id into ontology_version_id_value from ontology.versions
   where status = 'published' order by created_at desc, id limit 1;
  select id into resolver_model_id_value from ontology.model_versions
   where model_role = 'resolver' and status = 'active'
   order by created_at desc, id limit 1;
  select id into scorer_model_id_value from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc, id limit 1;
  select id into embedding_model_id_value from ontology.embedding_models
   where status = 'active' order by created_at desc, id limit 1;
  -- 0412: the active release joins the question "has this input been
  -- scored under the current analysis".
  select id into calibration_release_id_value
    from semantic_private.calibration_releases where status = 'active';

  if ontology_version_id_value is null
     or resolver_model_id_value is null
     or scorer_model_id_value is null then
    raise exception 'no published ontology or no active resolver/scorer to recompute against';
  end if;

  with candidates as (
    select s.user_id, s.revision
    from semantic_private.user_state_versions s
    where s.revision > 0
      and (p_user_id is null or s.user_id = p_user_id)
      and not exists (
        select 1 from semantic_private.semantic_runs r
        where r.user_id = s.user_id
          and r.input_revision = s.revision
          and r.ontology_version_id = ontology_version_id_value
          and r.resolver_model_id = resolver_model_id_value
          and r.scorer_model_id = scorer_model_id_value
          and r.calibration_release_id
              is not distinct from calibration_release_id_value
      )
  ), inserted as (
    insert into semantic_private.worker_jobs (
      job_type, user_id, payload, idempotency_key
    )
    select
      'recompute_user', c.user_id,
      jsonb_strip_nulls(jsonb_build_object(
        'user_id', c.user_id::text,
        'input_revision', c.revision,
        'ontology_version_id', ontology_version_id_value::text,
        'resolver_model_id', resolver_model_id_value::text,
        'scorer_model_id', scorer_model_id_value::text,
        'embedding_model_id', embedding_model_id_value::text
      )),
      'analysis-change:' || c.user_id::text || ':' || c.revision::text
        || ':' || ontology_version_id_value::text
        || ':' || resolver_model_id_value::text
        || ':' || scorer_model_id_value::text
        || ':' || coalesce(calibration_release_id_value::text, 'none')
    from candidates c
    on conflict (idempotency_key) do nothing
    returning 1
  )
  select count(*) into enqueued from inserted;

  raise notice 'enqueue_recompute_on_analysis_change(%): % job(s)', p_reason, enqueued;
  return enqueued;
end
$function$;

-- The neutral rescores, enqueued at last.
do $$
declare n integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    '0412: the identity learns the release; bootstrap-3 neutrality rescores enqueue')
    into n;
  raise notice '0412: % neutral rescore(s) enqueued', n;
end;
$$;

commit;
