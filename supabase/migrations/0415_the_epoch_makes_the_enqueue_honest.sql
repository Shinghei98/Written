-- 0415 — the analysis epoch makes the enqueue honest.
--
-- **Third recurrence of one defect, so the general fix (owner's session,
-- 2026-08-27).** A run's identity was (user, revision, ontology,
-- resolver, scorer) — then the calibration release joined it (0412)
-- because a release publish rescored nobody. Tonight 0414 superseded
-- 684 fabricated mention resolutions — an analysis change by any
-- honest reading — and again nothing rescored, because resolution
-- state is invisible to the identity too. Chasing scorer inputs into
-- the identity one at a time loses by induction.
--
-- The general lever: **an analysis epoch** — one monotonic counter,
-- bumped by `enqueue_recompute_on_analysis_change` itself. Declaring an
-- analysis change IS the bump; the current epoch joins the run identity
-- and the candidate filter, so a declared change guarantees exactly one
-- fresh run per user, and an undeclared no-op guarantees none. The
-- function's name finally tells the whole truth. (The calibration
-- release stays in the identity as well — an audit fact worth its
-- column — but the epoch alone now suffices to force the rescore.)

begin;

create table semantic_private.analysis_epoch (
  singleton boolean primary key default true check (singleton),
  epoch bigint not null default 0,
  bumped_at timestamptz not null default now(),
  reason text not null default 'genesis'
);
insert into semantic_private.analysis_epoch default values;
revoke all on semantic_private.analysis_epoch from public;
grant select on semantic_private.analysis_epoch to semantic_worker;

alter table semantic_private.semantic_runs
  add column analysis_epoch bigint;

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
  epoch_value bigint;
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
  select id into calibration_release_id_value
    from semantic_private.calibration_releases where status = 'active';

  if ontology_version_id_value is null
     or resolver_model_id_value is null
     or scorer_model_id_value is null then
    raise exception 'no published ontology or no active resolver/scorer to recompute against';
  end if;

  -- Declaring the change IS the epoch bump.
  update semantic_private.analysis_epoch
     set epoch = epoch + 1, bumped_at = now(), reason = left(p_reason, 500)
  returning epoch into epoch_value;

  with candidates as (
    select s.user_id, s.revision
    from semantic_private.user_state_versions s
    where s.revision > 0
      and (p_user_id is null or s.user_id = p_user_id)
      and not exists (
        select 1 from semantic_private.semantic_runs r
        where r.user_id = s.user_id
          and r.input_revision = s.revision
          and r.analysis_epoch is not distinct from epoch_value
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
        || ':epoch-' || epoch_value::text
    from candidates c
    on conflict (idempotency_key) do nothing
    returning 1
  )
  select count(*) into enqueued from inserted;

  raise notice 'enqueue_recompute_on_analysis_change(%): epoch %, % job(s)',
    p_reason, epoch_value, enqueued;
  return enqueued;
end
$function$;

-- The rescore that 0414 declared and could not deliver.
do $$
declare n integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    '0415: the epoch exists; 0414''s 684 held mentions rescore now')
    into n;
  raise notice '0415: % rescore(s) enqueued at the first epoch', n;
end;
$$;

commit;
