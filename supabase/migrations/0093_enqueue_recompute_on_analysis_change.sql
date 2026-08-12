-- 0093 — a changed scorer must be able to reach the data it re-scores.
--
-- **`0092` was necessary and not sufficient, and the second stop was invisible
-- until the first one was cleared.** There are two independent gates between a
-- changed model and a changed score, and both were shut:
--
--   1. `finalize_ingestion_run_v031` enqueues `recompute_user` **only inside
--      `if changed_count > 0`** (`0048:756`), and keys it
--      `ingestion-v031-recompute:<user>:<revision>`. An unchanged library
--      bumps no revision, so it enqueues nothing at all — four ingestion runs
--      in fifteen minutes produced zero jobs.
--   2. `semantic_run_live_identity_idx` returns `already_resolved` when the
--      identity is unchanged. That is what `0092` moved.
--
-- Both are right for what they were built for. Together they say something
-- nobody decided: **the analysis inputs can change and nothing recomputes.**
-- Publish a new ontology version, promote a new resolver, retire a scorer — the
-- work is enqueued by *ingestion*, so it happens only when somebody's data
-- happens to change afterwards. On a library that has stopped moving, never.
--
-- The gap is structural rather than a bug in either gate: ingestion is the only
-- thing that enqueues, and ingestion cannot see a model publish. So the fix is a
-- second entry point, not a change to the first — `finalize_ingestion_run_v031`
-- is 200 lines and is the wrong thing to reopen for this.
--
-- **Idempotence comes from the key naming what actually determines the run.**
-- The finalizer's key carries the revision alone, which is precisely why it
-- cannot express "same data, different scorer". This one carries the revision
-- *and* all three analysis ids, so calling it twice for the same inputs
-- enqueues nothing and calling it after a model publish enqueues exactly one
-- job per affected user.
--
-- **And it skips users a run already covers**, on the same tuple the live
-- identity index uses minus `input_hash` (which only the worker can compute).
-- A superset, deliberately: if such a run exists the job could only answer
-- `already_resolved`, and enqueuing fleet-wide no-ops on every model publish is
-- how a queue stops being worth reading.

begin;

create or replace function semantic_private.enqueue_recompute_on_analysis_change(
  p_reason text,
  p_user_id uuid default null
) returns integer
language plpgsql
security definer
set search_path = semantic_private, ontology, pg_catalog, public
as $$
declare
  ontology_version_id_value uuid;
  resolver_model_id_value uuid;
  scorer_model_id_value uuid;
  embedding_model_id_value uuid;
  enqueued integer := 0;
begin
  -- The same four selections `finalize_ingestion_run_v031` makes, in the same
  -- order, because a job enqueued here must be indistinguishable from one
  -- enqueued there. Two ways of choosing the current model would be two
  -- answers to one question.
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
      )
  ), inserted as (
    insert into semantic_private.worker_jobs (
      job_type, user_id, payload, idempotency_key
    )
    select
      'recompute_user', c.user_id,
      -- **The payload is a closed control message and `p_reason` may not enter
      -- it.** A first draft carried the reason here so a queue row would say
      -- why it exists; `worker_job_payload_is_valid_v03` refused the insert
      -- with `unknown_payload_field`, which is the guard doing exactly its job
      -- — a control message with an open shape is a channel, and a worker that
      -- reads one field it was not given is how a queue grows an API nobody
      -- designed. The reason belongs to the migration that supplies it, which
      -- is a durable record in a way a queue row is not: `worker_jobs` is
      -- swept, and `git log` is not.
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
    from candidates c
    on conflict (idempotency_key) do nothing
    returning 1
  )
  select count(*) into enqueued from inserted;

  -- `p_reason` is required and reaches no table, which is deliberate: it makes
  -- the caller say why out loud in the migration that calls this, where the
  -- reason survives. A parameter that only ever appears in a log line would
  -- normally be a smell; here it is the one place the *why* can live, since the
  -- payload is closed.
  raise notice 'enqueue_recompute_on_analysis_change(%): % job(s)', p_reason, enqueued;

  return enqueued;
end
$$;

revoke all on function semantic_private.enqueue_recompute_on_analysis_change(text, uuid)
  from public;

-- **Called here, because `0092` is the change this exists for.** A migration
-- that promotes a model version and does not enqueue the recompute has changed
-- what the system *would* compute and nothing it *has* computed — which is the
-- state this pair of migrations was written to get out of. Any future migration
-- publishing an ontology version or activating a model should end with this
-- call for the same reason.
--
-- No assertion on the count: on a from-empty replay there are no users and the
-- honest answer is zero. A migration that demanded work to do could not be
-- replayed, and replayability is what proved this chain builds a schema from
-- nothing.
do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.2.0: hubs scored, never asserted; classical performers by album breadth'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for the 0.2.0 scorer', enqueued;
end
$$;

commit;
