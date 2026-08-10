-- Guards, row-level security and the authenticated RPC surface, adapted from
-- the v0.3.1 package's `sql/002_rls_and_rpc.sql`.
--
-- **The schema-wide statements are the reason this file is adapted rather than
-- copied.** The reference contains, at its lines 927–941:
--
--     revoke all on schema private from public, anon, authenticated, service_role;
--     revoke all on all tables in schema private from ... service_role;
--     grant  select, insert, update on all tables in schema private to service_role;
--
-- Against this app those would land on `private.push_config`, `private.notify`
-- and `private.collaborators`.
--
-- **It is the grant that does the damage, not the revoke.** Measured on a clean
-- replay, `service_role` has no usage on `private` to begin with, so the revoke
-- is a no-op; push works because `private.notify` is `security definer` and
-- runs as its owner. The grant is the problem: it would hand `service_role`
-- read and write on `private.push_config`, which holds the shared push secret
-- and which `0020` closed on purpose, and on `private.collaborators`, which
-- `0041` put in an ungranted schema so that nobody could mark themselves a
-- collaborator. Broadening access is the integration plan's own stated failure
-- condition.
--
-- Translated to `semantic_private`, the schema-wide form becomes *exactly*
-- scoped rather than dangerous: that schema contains only objects `0042`
-- created, so "all tables in schema semantic_private" is a precise enumeration
-- of them and nothing else. The integration plan asks for explicit per-object
-- grants; once the namespace is right, the schema-wide statement means the same
-- set. What it does **not** cover is tables added by later migrations, which
-- must carry their own grants — the default privileges revoked in `0042` are
-- what makes that failure loud rather than silent.
--
-- **One thing here is not a migration.** This grants `usage on schema api to
-- authenticated`, and whether `api` is reachable from the client also depends
-- on Supabase's exposed-schemas setting in the dashboard. The plan's position is
-- that only `api` should ever be exposed, and never `semantic_private`, the
-- app's `private`, or `ontology`. A migration cannot assert that; check it.
--
-- **Ships no product behaviour**, like `0042`. Nothing in the app calls these
-- functions yet.
--
-- Adapted against package v0.3.1, app commit 8203353, migration head 0041.

begin;

-- -------------------------------------------------------------------------
-- Published ontology versions are immutable and hierarchy publication fails
-- if a longer broader-edge cycle exists.
-- -------------------------------------------------------------------------

create or replace function ontology.guard_published_version()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  version_id uuid;
  version_status text;
  old_version_status text;
begin
  version_id := case when tg_op = 'DELETE'
    then old.ontology_version_id else new.ontology_version_id end;
  select status into version_status
  from ontology.versions
  where id = version_id;
  if version_status in ('published', 'retired') then
    raise exception 'published or retired ontology versions are immutable';
  end if;
  if tg_op = 'UPDATE' then
    select status into old_version_status
    from ontology.versions
    where id = old.ontology_version_id;
    if old_version_status in ('published', 'retired') then
      raise exception 'published or retired ontology versions are immutable';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger concept_revisions_guard_published
before insert or update or delete on ontology.concept_revisions
for each row execute function ontology.guard_published_version();

create trigger concept_labels_guard_published
before insert or update or delete on ontology.concept_labels
for each row execute function ontology.guard_published_version();

create trigger concept_edges_guard_published
before insert or update or delete on ontology.concept_edges
for each row execute function ontology.guard_published_version();

create trigger external_concept_links_guard_published
before insert or update or delete on ontology.external_concept_links
for each row execute function ontology.guard_published_version();

create trigger concept_embeddings_guard_published
before insert or update or delete on ontology.concept_embeddings_384
for each row execute function ontology.guard_published_version();

create trigger motif_rules_guard_published
before insert or update or delete on ontology.motif_rules
for each row execute function ontology.guard_published_version();

-- Relation types are global rather than versioned. Once referenced, their
-- inference contract cannot be changed underneath historical graph rows.
create or replace function ontology.guard_relation_type_contract()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if row(
       new.predicate_key, new.relation_class, new.inverse_predicate_key,
       new.is_symmetric, new.transitive_for_inference,
       new.max_inference_hops, new.assertion_safe
     ) is distinct from row(
       old.predicate_key, old.relation_class, old.inverse_predicate_key,
       old.is_symmetric, old.transitive_for_inference,
       old.max_inference_hops, old.assertion_safe
     ) and (
       exists (
         select 1 from ontology.concept_edges
         where predicate_key = old.predicate_key
       ) or exists (
         select 1 from semantic_private.user_assertions
         where predicate_key = old.predicate_key
       ) or exists (
         select 1 from ontology.motif_rules
         where evidence_predicate_key = old.predicate_key
            or output_predicate_key = old.predicate_key
       )
     )
  then
    raise exception 'referenced relation type contracts are immutable';
  end if;
  return new;
end;
$$;

create trigger relation_types_guard_contract
before update on ontology.relation_types
for each row execute function ontology.guard_relation_type_contract();

create or replace function ontology.guard_concept_edge_relation_class()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  actual_class text;
begin
  select relation_class into actual_class
  from ontology.relation_types
  where predicate_key = new.predicate_key;
  if actual_class is null or actual_class not in (
    'hierarchical', 'associative', 'descriptive'
  ) then
    raise exception 'concept edge predicate % has invalid relation class %',
      new.predicate_key, coalesce(actual_class, '<missing>');
  end if;
  return new;
end;
$$;

create trigger concept_edges_guard_relation_class
before insert or update of predicate_key on ontology.concept_edges
for each row execute function ontology.guard_concept_edge_relation_class();

create or replace function semantic_private.guard_user_assertion_relation_class()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  actual_class text;
  safe_for_assertions boolean;
  revision_status text;
  revision_sensitivity text;
  revision_inference_policy text;
begin
  select relation_class, assertion_safe
  into actual_class, safe_for_assertions
  from ontology.relation_types
  where predicate_key = new.predicate_key;
  if actual_class is distinct from 'user_claim' then
    raise exception 'user assertion predicate % must be a user_claim',
      new.predicate_key;
  end if;
  if new.assertion_origin = 'inferred'
     and safe_for_assertions is distinct from true then
    raise exception 'inferred assertion predicate % is not assertion-safe',
      new.predicate_key;
  end if;
  if new.assertion_origin = 'inferred' and new.concept_id is not null then
    select status, sensitivity, inference_policy
    into revision_status, revision_sensitivity, revision_inference_policy
    from ontology.concept_revisions
    where ontology_version_id = new.created_ontology_version_id
      and concept_id = new.concept_id;
    if revision_status is distinct from 'active'
       or revision_sensitivity = 'sensitive'
       or revision_inference_policy not in ('inferable', 'review_required')
    then
      raise exception 'concept is not eligible for inferred user assertions';
    end if;
  end if;
  return new;
end;
$$;

create trigger user_assertions_guard_relation_class
before insert or update of
  predicate_key, assertion_origin, concept_id, created_ontology_version_id
on semantic_private.user_assertions
for each row execute function semantic_private.guard_user_assertion_relation_class();

create or replace function ontology.guard_motif_rule_relation_classes()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  evidence_class text;
  output_class text;
  output_assertion_safe boolean;
begin
  select relation_class into evidence_class
  from ontology.relation_types
  where predicate_key = new.evidence_predicate_key;
  select relation_class, assertion_safe
  into output_class, output_assertion_safe
  from ontology.relation_types
  where predicate_key = new.output_predicate_key;
  if evidence_class is null or evidence_class not in (
    'hierarchical', 'associative', 'descriptive'
  ) then
    raise exception 'motif evidence predicate must be a concept-edge relation';
  end if;
  if output_class is distinct from 'user_claim'
     or output_assertion_safe is distinct from true then
    raise exception 'motif output predicate must be an assertion-safe user claim';
  end if;
  return new;
end;
$$;

create trigger motif_rules_guard_relation_classes
before insert or update of evidence_predicate_key, output_predicate_key
on ontology.motif_rules
for each row execute function ontology.guard_motif_rule_relation_classes();

create or replace function ontology.has_broader_cycle(target_version_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  with recursive walk(start_node, current_node, path, cycle) as (
    select
      edge.subject_concept_id,
      edge.object_concept_id,
      array[edge.subject_concept_id, edge.object_concept_id]::uuid[],
      edge.object_concept_id = edge.subject_concept_id
    from ontology.concept_edges as edge
    where edge.ontology_version_id = target_version_id
      and edge.predicate_key = 'broader'
      and edge.status = 'active'

    union all

    select
      walk.start_node,
      edge.object_concept_id,
      walk.path || edge.object_concept_id,
      edge.object_concept_id = any(walk.path)
    from walk
    join ontology.concept_edges as edge
      on edge.ontology_version_id = target_version_id
     and edge.predicate_key = 'broader'
     and edge.status = 'active'
     and edge.subject_concept_id = walk.current_node
    where not walk.cycle
  )
  select coalesce(bool_or(cycle), false) from walk;
$$;

create or replace function ontology.publish_version(target_version_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  lock table ontology.versions in share row exclusive mode;
  if not exists (
    select 1 from ontology.versions
    where id = target_version_id and status = 'draft'
  ) then
    raise exception 'target ontology version must exist and be draft';
  end if;
  if ontology.has_broader_cycle(target_version_id) then
    raise exception 'cannot publish ontology with broader-edge cycle';
  end if;
  if exists (
    select 1
    from ontology.concept_edges as edge
    left join ontology.external_entities as entity
      on entity.id = nullif(edge.provenance->>'external_entity_id', '')::uuid
    where edge.ontology_version_id = target_version_id
      and edge.status = 'active'
      and edge.provenance_type = 'external'
      and entity.id is null
  ) then
    raise exception 'active external edge lacks resolvable provenance';
  end if;

  update ontology.versions
  set status = 'retired'
  where status = 'published';

  update ontology.versions
  set status = 'published', published_at = now()
  where id = target_version_id;
end;
$$;

revoke all on function ontology.publish_version(uuid) from public;

-- -------------------------------------------------------------------------
-- Default-deny the semantic evidence schema. The app receives no table grants;
-- it can only use the API functions below. RLS remains protection if schema
-- exposure is accidentally changed later.
-- -------------------------------------------------------------------------

alter table semantic_private.sources enable row level security;
alter table semantic_private.source_connections enable row level security;
alter table semantic_private.source_coverage enable row level security;
alter table semantic_private.ingestion_runs enable row level security;
alter table semantic_private.observations enable row level security;
alter table semantic_private.observation_mentions enable row level security;
alter table semantic_private.semantic_runs enable row level security;
alter table semantic_private.observation_mappings enable row level security;
alter table semantic_private.concept_source_scores enable row level security;
alter table semantic_private.concept_scores enable row level security;
alter table semantic_private.motif_instances enable row level security;
alter table semantic_private.motif_support enable row level security;
alter table semantic_private.user_terms enable row level security;
alter table semantic_private.user_assertions enable row level security;
alter table semantic_private.assertion_score_versions enable row level security;
alter table semantic_private.assertion_current_scores enable row level security;
alter table semantic_private.assertion_evidence enable row level security;
alter table semantic_private.assertion_exposures enable row level security;
alter table semantic_private.feedback_events enable row level security;
alter table semantic_private.assertion_preferences enable row level security;
alter table semantic_private.user_suppressions enable row level security;
alter table semantic_private.mapping_feedback_labels enable row level security;
alter table semantic_private.user_state_versions enable row level security;
alter table semantic_private.rule_feedback_stats enable row level security;
alter table semantic_private.emergent_terms enable row level security;
alter table semantic_private.emergent_term_relations enable row level security;
alter table semantic_private.worker_jobs enable row level security;

create or replace function semantic_private.lock_user_state(target_user_id uuid)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  current_revision bigint;
begin
  insert into semantic_private.user_state_versions (user_id, revision)
  values (target_user_id, 0)
  on conflict (user_id) do nothing;

  select revision into current_revision
  from semantic_private.user_state_versions
  where user_id = target_user_id
  for update;
  return current_revision;
end;
$$;

create or replace function semantic_private.bump_user_state_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into semantic_private.user_state_versions (user_id, revision)
  values (new.user_id, 1)
  on conflict (user_id) do update
  set revision = semantic_private.user_state_versions.revision + 1,
      updated_at = now();
  return new;
end;
$$;

create or replace function semantic_private.guard_user_state_revision_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.revision <> old.revision + 1 then
    raise exception 'user state revision must advance by exactly one';
  end if;
  return new;
end;
$$;

create trigger user_state_versions_guard_monotonic
before update on semantic_private.user_state_versions
for each row execute function semantic_private.guard_user_state_revision_update();

create trigger source_connections_insert_bump_semantic_revision
after insert on semantic_private.source_connections
for each row execute function semantic_private.bump_user_state_revision();

create trigger source_connections_update_bump_semantic_revision
after update of connection_state, granted_scopes, revoked_at
on semantic_private.source_connections
for each row when (
  old.connection_state is distinct from new.connection_state
  or old.granted_scopes is distinct from new.granted_scopes
  or old.revoked_at is distinct from new.revoked_at
)
execute function semantic_private.bump_user_state_revision();

create trigger source_coverage_bump_semantic_revision
after insert on semantic_private.source_coverage
for each row execute function semantic_private.bump_user_state_revision();

create trigger ingestion_run_insert_bump_semantic_revision
after insert on semantic_private.ingestion_runs
for each row when (new.status = 'succeeded')
execute function semantic_private.bump_user_state_revision();

create trigger ingestion_run_update_bump_semantic_revision
after update of status on semantic_private.ingestion_runs
for each row when (
  new.status = 'succeeded' and old.status is distinct from new.status
)
execute function semantic_private.bump_user_state_revision();

create trigger observation_lifecycle_bump_semantic_revision
after update of lifecycle_state on semantic_private.observations
for each row when (old.lifecycle_state is distinct from new.lifecycle_state)
execute function semantic_private.bump_user_state_revision();

create trigger feedback_event_bump_semantic_revision
after insert on semantic_private.feedback_events
for each row execute function semantic_private.bump_user_state_revision();

create or replace function semantic_private.guard_new_run_running()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status <> 'running' then
    raise exception 'new runs must start in running status';
  end if;
  return new;
end;
$$;

create trigger ingestion_runs_guard_insert
before insert on semantic_private.ingestion_runs
for each row execute function semantic_private.guard_new_run_running();

create trigger semantic_runs_guard_insert
before insert on semantic_private.semantic_runs
for each row execute function semantic_private.guard_new_run_running();

create or replace function semantic_private.guard_ingestion_run_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from semantic_private.sources
    where source_code = new.source_code and active
  ) then
    raise exception 'ingestion run source is inactive or missing';
  end if;
  return new;
end;
$$;

create trigger ingestion_runs_guard_source
before insert on semantic_private.ingestion_runs
for each row execute function semantic_private.guard_ingestion_run_source();

create or replace function semantic_private.guard_semantic_run_contract()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from ontology.versions
    where id = new.ontology_version_id and status = 'published'
  ) then
    raise exception 'semantic runs must start on the published ontology version';
  end if;
  if not exists (
    select 1 from ontology.model_versions
    where id = new.resolver_model_id
      and model_role = 'resolver'
      and status = 'active'
  ) or not exists (
    select 1 from ontology.model_versions
    where id = new.scorer_model_id
      and model_role = 'scorer'
      and status = 'active'
  ) then
    raise exception 'semantic run model roles or statuses are invalid';
  end if;
  if new.embedding_model_id is not null and not exists (
    select 1 from ontology.embedding_models
    where id = new.embedding_model_id and status = 'active'
  ) then
    raise exception 'semantic run embedding model is inactive or missing';
  end if;
  return new;
end;
$$;

create trigger semantic_runs_guard_contract
before insert on semantic_private.semantic_runs
for each row execute function semantic_private.guard_semantic_run_contract();

create or replace function semantic_private.guard_ingestion_run_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.source_code is distinct from old.source_code
     or new.connector_version is distinct from old.connector_version
     or new.input_hash is distinct from old.input_hash
     or new.started_at is distinct from old.started_at
  then
    raise exception 'ingestion run identity is immutable';
  end if;
  if old.status <> 'running' and new is distinct from old then
    raise exception 'terminal ingestion runs are immutable';
  end if;
  return new;
end;
$$;

create trigger ingestion_runs_guard_update
before update on semantic_private.ingestion_runs
for each row execute function semantic_private.guard_ingestion_run_update();

create or replace function semantic_private.guard_observation_ingestion_run()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from semantic_private.ingestion_runs
    where id = new.ingestion_run_id
      and user_id = new.user_id
      and source_code = new.source_code
      and status = 'running'
  ) then
    raise exception 'observations may only be appended to their running ingestion run';
  end if;
  return new;
end;
$$;

create trigger observations_guard_ingestion_run
before insert on semantic_private.observations
for each row execute function semantic_private.guard_observation_ingestion_run();

create or replace function semantic_private.guard_semantic_run_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.ontology_version_id is distinct from old.ontology_version_id
     or new.resolver_model_id is distinct from old.resolver_model_id
     or new.scorer_model_id is distinct from old.scorer_model_id
     or new.embedding_model_id is distinct from old.embedding_model_id
     or new.input_revision is distinct from old.input_revision
     or new.input_hash is distinct from old.input_hash
     or new.started_at is distinct from old.started_at
  then
    raise exception 'semantic run identity is immutable';
  end if;
  if old.status <> 'running' and new is distinct from old then
    raise exception 'terminal semantic runs are immutable';
  end if;
  if old.status = 'running'
     and new.status = 'succeeded'
     and current_setting('written.finalizing_semantic_run', true)
           is distinct from new.id::text
  then
    raise exception 'semantic runs must be succeeded by finalization';
  end if;
  return new;
end;
$$;

create trigger semantic_runs_guard_update
before update on semantic_private.semantic_runs
for each row execute function semantic_private.guard_semantic_run_update();

create or replace function semantic_private.guard_semantic_output_writable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and new.semantic_run_id is distinct from old.semantic_run_id then
    raise exception 'semantic output run identity is immutable';
  end if;
  if not exists (
    select 1 from semantic_private.semantic_runs
    where id = new.semantic_run_id
      and user_id = new.user_id
      and status = 'running'
  ) then
    raise exception 'semantic output may only be written by its running run';
  end if;
  return new;
end;
$$;

create trigger observation_mappings_guard_running
before insert or update on semantic_private.observation_mappings
for each row execute function semantic_private.guard_semantic_output_writable();

create trigger concept_source_scores_guard_running
before insert or update on semantic_private.concept_source_scores
for each row execute function semantic_private.guard_semantic_output_writable();

create trigger concept_scores_guard_running
before insert or update on semantic_private.concept_scores
for each row execute function semantic_private.guard_semantic_output_writable();

create trigger motif_instances_guard_running
before insert or update on semantic_private.motif_instances
for each row execute function semantic_private.guard_semantic_output_writable();

create trigger motif_support_guard_running
before insert or update on semantic_private.motif_support
for each row execute function semantic_private.guard_semantic_output_writable();

create trigger assertion_scores_guard_running
before insert or update on semantic_private.assertion_score_versions
for each row execute function semantic_private.guard_semantic_output_writable();

create or replace function semantic_private.guard_assertion_evidence_writable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and row(
       new.assertion_score_version_id, new.user_id,
       new.observation_mapping_id
     ) is distinct from row(
       old.assertion_score_version_id, old.user_id,
       old.observation_mapping_id
     )
  then
    raise exception 'assertion evidence identity is immutable';
  end if;
  if not exists (
    select 1
    from semantic_private.assertion_score_versions as score
    join semantic_private.semantic_runs as run
      on run.id = score.semantic_run_id
     and run.user_id = score.user_id
    where score.id = new.assertion_score_version_id
      and score.user_id = new.user_id
      and run.status = 'running'
  ) then
    raise exception 'assertion evidence may only be written by its running run';
  end if;
  return new;
end;
$$;

create trigger assertion_evidence_guard_running
before insert or update on semantic_private.assertion_evidence
for each row execute function semantic_private.guard_assertion_evidence_writable();

create or replace function semantic_private.assert_surface_allowed(surface_name text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if surface_name is distinct from 'memories' then
    raise exception 'unsupported assertion surface';
  end if;
end;
$$;

create or replace function semantic_private.reject_stale_inferred_assertion()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_revision bigint;
  run_status text;
  current_revision bigint;
begin
  if new.assertion_origin <> 'inferred' then
    return new;
  end if;
  select input_revision, status into run_revision, run_status
  from semantic_private.semantic_runs
  where id = new.source_semantic_run_id and user_id = new.user_id;
  select revision into current_revision
  from semantic_private.user_state_versions
  where user_id = new.user_id;
  current_revision := coalesce(current_revision, 0);
  if run_revision is null
     or run_revision <> current_revision
     or run_status <> 'running' then
    raise exception 'stale semantic run cannot create a user assertion';
  end if;
  return new;
end;
$$;

create trigger user_assertions_reject_stale_run
before insert or update of source_semantic_run_id on semantic_private.user_assertions
for each row execute function semantic_private.reject_stale_inferred_assertion();

create or replace function semantic_private.guard_motif_score_output()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.motif_instance_id is not null and not exists (
    select 1
    from semantic_private.motif_instances as motif
    join semantic_private.user_assertions as assertion
      on assertion.id = new.assertion_id
     and assertion.user_id = new.user_id
     and assertion.concept_id = motif.output_concept_id
    where motif.id = new.motif_instance_id
      and motif.user_id = new.user_id
      and motif.semantic_run_id = new.semantic_run_id
      and motif.ontology_version_id = new.ontology_version_id
  ) then
    raise exception 'motif output must match the scored assertion concept';
  end if;
  return new;
end;
$$;

create trigger assertion_scores_guard_motif_output
before insert or update of
  motif_instance_id, assertion_id, user_id, semantic_run_id, ontology_version_id
on semantic_private.assertion_score_versions
for each row execute function semantic_private.guard_motif_score_output();

create or replace function semantic_private.guard_current_score_pointer()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  score_run_revision bigint;
  score_run_status text;
  current_revision bigint;
begin
  select run.input_revision, run.status
  into score_run_revision, score_run_status
  from semantic_private.assertion_score_versions as score
  join semantic_private.semantic_runs as run
    on run.id = score.semantic_run_id
   and run.user_id = score.user_id
  where score.id = new.assertion_score_version_id
    and score.user_id = new.user_id
    and score.assertion_id = new.assertion_id
    and score.semantic_run_id = new.semantic_run_id;
  if not found or score_run_status <> 'succeeded' then
    raise exception 'current score must belong to a succeeded semantic run';
  end if;

  select revision into current_revision
  from semantic_private.user_state_versions
  where user_id = new.user_id;
  if score_run_revision <> coalesce(current_revision, 0) then
    raise exception 'current score run does not match the exact user revision';
  end if;
  return new;
end;
$$;

create trigger assertion_current_scores_guard_exact_revision
before insert or update on semantic_private.assertion_current_scores
for each row execute function semantic_private.guard_current_score_pointer();

create or replace function semantic_private.guard_assertion_exposure_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'assertion exposures are append-only';
  end if;
  if new.assertion_score_version_id is null then
    if not exists (
      select 1 from semantic_private.user_assertions
      where id = new.assertion_id
        and user_id = new.user_id
        and assertion_origin <> 'inferred'
        and created_ontology_version_id = new.ontology_version_id
    ) then
      raise exception 'unscored exposure must identify an explicit assertion version';
    end if;
  elsif not exists (
    select 1
    from semantic_private.assertion_current_scores as current_score
    join semantic_private.assertion_score_versions as score
      on score.id = current_score.assertion_score_version_id
     and score.user_id = current_score.user_id
     and score.assertion_id = current_score.assertion_id
    join semantic_private.semantic_runs as run
      on run.id = current_score.semantic_run_id
     and run.user_id = current_score.user_id
     and run.status = 'succeeded'
    left join semantic_private.user_state_versions as user_state
      on user_state.user_id = current_score.user_id
    where current_score.assertion_id = new.assertion_id
      and current_score.user_id = new.user_id
      and current_score.assertion_score_version_id =
            new.assertion_score_version_id
      and score.ontology_version_id = new.ontology_version_id
      and run.input_revision = coalesce(user_state.revision, 0)
  ) then
    raise exception 'scored exposure must identify the exact current score';
  end if;
  return new;
end;
$$;

create trigger assertion_exposures_guard_immutable
before insert or update on semantic_private.assertion_exposures
for each row execute function semantic_private.guard_assertion_exposure_immutable();

create or replace function semantic_private.guard_feedback_event_fidelity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  exposure_row semantic_private.assertion_exposures%rowtype;
begin
  if tg_op = 'UPDATE' then
    raise exception 'feedback events are append-only';
  end if;
  if jsonb_typeof(new.context) <> 'object'
     or exists (
       select 1
       from jsonb_object_keys(new.context) as key_name
       where key_name not in ('surface', 'linked_observation_count')
     )
     or (new.action <> 'explicit_add' and new.context ? 'linked_observation_count')
  then
    raise exception 'feedback context contains unsupported fields';
  end if;
  perform semantic_private.assert_surface_allowed(new.context->>'surface');
  if new.exposure_id is not null then
    select * into exposure_row
    from semantic_private.assertion_exposures
    where id = new.exposure_id
      and user_id = new.user_id
      and assertion_id = new.assertion_id;
    if not found
       or new.ontology_version_id is distinct from exposure_row.ontology_version_id
       or new.assertion_score_version_id is distinct from
            exposure_row.assertion_score_version_id
       or new.presentation_version is distinct from exposure_row.presentation_version
       or new.context->>'surface' is distinct from exposure_row.surface
    then
      raise exception 'feedback event does not faithfully match its exposure';
    end if;
  end if;
  return new;
end;
$$;

create trigger feedback_events_guard_fidelity
before insert or update on semantic_private.feedback_events
for each row execute function semantic_private.guard_feedback_event_fidelity();

create or replace function semantic_private.finalize_semantic_run(target_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row semantic_private.semantic_runs%rowtype;
  current_revision bigint;
begin
  select * into run_row
  from semantic_private.semantic_runs
  where id = target_run_id
  for update;
  if not found then
    raise exception 'semantic run not found';
  end if;
  if run_row.status = 'succeeded' then
    return true;
  elsif run_row.status = 'stale' then
    return false;
  elsif run_row.status <> 'running' then
    raise exception 'only a running semantic run can be finalized';
  end if;

  current_revision := semantic_private.lock_user_state(run_row.user_id);
  if run_row.input_revision <> current_revision then
    update semantic_private.semantic_runs
    set status = 'stale', finished_at = now(), error_code = 'input_revision_changed'
    where id = run_row.id;
    return false;
  end if;

  perform set_config('written.finalizing_semantic_run', run_row.id::text, true);
  update semantic_private.semantic_runs
  set status = 'succeeded', finished_at = now(), error_code = null
  where id = run_row.id;

  insert into semantic_private.assertion_current_scores (
    assertion_id, user_id, assertion_score_version_id, semantic_run_id,
    finalized_at
  )
  select
    score.assertion_id, score.user_id, score.id, score.semantic_run_id, now()
  from semantic_private.assertion_score_versions as score
  where score.semantic_run_id = run_row.id
    and score.user_id = run_row.user_id
  on conflict (assertion_id, user_id) do update
  set assertion_score_version_id = excluded.assertion_score_version_id,
      semantic_run_id = excluded.semantic_run_id,
      finalized_at = excluded.finalized_at;

  return true;
end;
$$;

revoke all on function semantic_private.finalize_semantic_run(uuid) from public;

revoke all on schema ontology from public, anon, authenticated, service_role;
revoke all on schema semantic_private from public, anon, authenticated, service_role;
revoke all on all tables in schema ontology from public, anon, authenticated, service_role;
revoke all on all tables in schema semantic_private from public, anon, authenticated, service_role;
revoke all on all sequences in schema ontology from public, anon, authenticated, service_role;
revoke all on all sequences in schema semantic_private from public, anon, authenticated, service_role;
revoke all on all functions in schema ontology from public;
revoke all on all functions in schema semantic_private from public;
revoke all on all functions in schema ontology from service_role;
revoke all on all functions in schema semantic_private from service_role;

-- The semantic worker uses only the trusted service role. Data API roles retain
-- no schema/table access and use the narrow api functions below.
grant usage on schema ontology, semantic_private to service_role;
grant select on all tables in schema ontology to service_role;
grant select, insert, update on all tables in schema semantic_private to service_role;
grant insert on table ontology.external_entities to service_role;
grant insert, update on table ontology.edge_proposals to service_role;
grant execute on function semantic_private.finalize_semantic_run(uuid) to service_role;

-- -------------------------------------------------------------------------
-- Small authenticated RPC surface
-- -------------------------------------------------------------------------

create or replace function api.list_assertions()
returns table (
  assertion_id uuid,
  predicate_key text,
  label text,
  origin text,
  display_state text,
  strength double precision,
  confidence double precision,
  breadth integer,
  stability double precision,
  surfacing_score double precision,
  display_payload jsonb,
  assertion_score_version_id uuid,
  ontology_version_id uuid
)
language sql
stable
security definer
set search_path = ''
as $$
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
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
$$;

create or replace function api.record_assertion_exposure(
  p_target_assertion_id uuid,
  p_assertion_score_version_id uuid,
  p_presentation_version text,
  p_displayed_label text,
  p_rank integer default null,
  p_surface_name text default 'memories'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  assertion_row semantic_private.user_assertions%rowtype;
  exposure_id uuid;
  version_id uuid;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;
  perform semantic_private.assert_surface_allowed(p_surface_name);
  if p_presentation_version is null
     or char_length(btrim(p_presentation_version)) not between 1 and 80 then
    raise exception 'invalid presentation version';
  end if;
  if p_displayed_label is null
     or char_length(btrim(p_displayed_label)) not between 1 and 240 then
    raise exception 'invalid displayed label';
  end if;
  if p_rank is not null and p_rank < 0 then
    raise exception 'rank must be nonnegative';
  end if;

  select * into assertion_row
  from semantic_private.user_assertions
  where id = p_target_assertion_id
    and user_id = actor_id
    and machine_state in ('candidate', 'eligible')
  for share;
  if not found then
    raise exception 'assertion not found or unavailable';
  end if;

  if p_assertion_score_version_id is not null then
    select score.ontology_version_id into version_id
    from semantic_private.assertion_current_scores as current_score
    join semantic_private.assertion_score_versions as score
      on score.id = current_score.assertion_score_version_id
     and score.user_id = current_score.user_id
     and score.assertion_id = current_score.assertion_id
    join semantic_private.semantic_runs as run
      on run.id = current_score.semantic_run_id
     and run.user_id = current_score.user_id
    left join semantic_private.user_state_versions as user_state
      on user_state.user_id = current_score.user_id
    where current_score.assertion_id = assertion_row.id
      and current_score.user_id = actor_id
      and current_score.assertion_score_version_id = p_assertion_score_version_id
      and run.status = 'succeeded'
      and run.input_revision = coalesce(user_state.revision, 0);
    if not found then
      raise exception 'score is not the finalized current score for assertion';
    end if;
  elsif assertion_row.assertion_origin = 'inferred' then
    raise exception 'inferred assertion exposure requires its current score';
  else
    version_id := assertion_row.created_ontology_version_id;
  end if;

  if exists (
    select 1
    from semantic_private.assertion_preferences as preference
    where preference.assertion_id = assertion_row.id
      and preference.user_id = actor_id
      and preference.display_state = 'suppressed'
  ) or exists (
    select 1
    from semantic_private.user_suppressions as suppression
    where suppression.user_id = actor_id
      and suppression.predicate_key = assertion_row.predicate_key
      and suppression.surface = p_surface_name
      and suppression.active
      and (
        (assertion_row.concept_id is not null and suppression.concept_id = assertion_row.concept_id) or
        (assertion_row.user_term_id is not null and suppression.user_term_id = assertion_row.user_term_id)
      )
  ) then
    raise exception 'suppressed assertion cannot be recorded as exposed';
  end if;

  insert into semantic_private.assertion_exposures (
    assertion_id, user_id, assertion_score_version_id,
    ontology_version_id, surface, presentation_version, displayed_label, rank
  ) values (
    assertion_row.id, actor_id, p_assertion_score_version_id,
    version_id, p_surface_name, btrim(p_presentation_version),
    btrim(p_displayed_label), p_rank
  ) returning id into exposure_id;
  return exposure_id;
end;
$$;

create or replace function api.suppress_assertion(
  p_target_assertion_id uuid,
  p_client_event_id uuid,
  p_exposure_id uuid,
  p_surface_name text default 'memories'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  assertion_row semantic_private.user_assertions%rowtype;
  exposure_row semantic_private.assertion_exposures%rowtype;
  existing_event semantic_private.feedback_events%rowtype;
  event_id uuid;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;
  perform semantic_private.assert_surface_allowed(p_surface_name);
  perform semantic_private.lock_user_state(actor_id);

  select * into assertion_row
  from semantic_private.user_assertions
  where id = p_target_assertion_id and user_id = actor_id
  for update;
  if not found then
    raise exception 'assertion not found';
  end if;

  select * into existing_event
  from semantic_private.feedback_events
  where user_id = actor_id and client_event_id = p_client_event_id;
  if found then
    if existing_event.assertion_id <> p_target_assertion_id
       or existing_event.action <> 'suppress'
       or existing_event.exposure_id is distinct from p_exposure_id
       or existing_event.context->>'surface' is distinct from p_surface_name then
      raise exception 'client_event_id already used for another action';
    end if;
    return existing_event.id;
  end if;

  select * into exposure_row
  from semantic_private.assertion_exposures
  where id = p_exposure_id
    and user_id = actor_id
    and assertion_id = p_target_assertion_id
    and surface = p_surface_name;
  if not found then
    raise exception 'matching assertion exposure is required';
  end if;

  insert into semantic_private.feedback_events (
    user_id, assertion_id, action, label_semantics, client_event_id,
    exposure_id, ontology_version_id, assertion_score_version_id,
    presentation_version, context
  ) values (
    actor_id, p_target_assertion_id, 'suppress', 'ambiguous_rejection', p_client_event_id,
    exposure_row.id, exposure_row.ontology_version_id,
    exposure_row.assertion_score_version_id, exposure_row.presentation_version,
    jsonb_build_object('surface', p_surface_name)
  ) returning id into event_id;

  insert into semantic_private.assertion_preferences (
    assertion_id, user_id, display_state, last_feedback_event_id
  ) values (
    p_target_assertion_id, actor_id, 'suppressed', event_id
  )
  on conflict (assertion_id, user_id) do update
  set display_state = 'suppressed',
      last_feedback_event_id = excluded.last_feedback_event_id,
      updated_at = now();

  update semantic_private.user_suppressions
  set source_feedback_event_id = event_id,
      active = true,
      lifted_by_feedback_event_id = null,
      lifted_at = null
  where user_id = actor_id
    and predicate_key = assertion_row.predicate_key
    and surface = p_surface_name
    and (
      (assertion_row.concept_id is not null and concept_id = assertion_row.concept_id) or
      (assertion_row.user_term_id is not null and user_term_id = assertion_row.user_term_id)
    )
    and active;

  if not found then
    insert into semantic_private.user_suppressions (
      user_id, concept_id, user_term_id, predicate_key, surface,
      source_feedback_event_id, active
    ) values (
      actor_id, assertion_row.concept_id, assertion_row.user_term_id,
      assertion_row.predicate_key, p_surface_name, event_id, true
    );
  end if;

  return event_id;
end;
$$;

create or replace function api.restore_assertion(
  p_target_assertion_id uuid,
  p_client_event_id uuid,
  p_surface_name text default 'memories'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  assertion_row semantic_private.user_assertions%rowtype;
  existing_event semantic_private.feedback_events%rowtype;
  event_id uuid;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;
  perform semantic_private.assert_surface_allowed(p_surface_name);
  perform semantic_private.lock_user_state(actor_id);
  select * into assertion_row
  from semantic_private.user_assertions
  where id = p_target_assertion_id and user_id = actor_id
  for update;
  if not found then raise exception 'assertion not found'; end if;

  select * into existing_event
  from semantic_private.feedback_events
  where user_id = actor_id and client_event_id = p_client_event_id;
  if found then
    if existing_event.assertion_id <> p_target_assertion_id
       or existing_event.action <> 'restore'
       or existing_event.context->>'surface' is distinct from p_surface_name then
      raise exception 'client_event_id already used for another action';
    end if;
    return existing_event.id;
  end if;

  insert into semantic_private.feedback_events (
    user_id, assertion_id, action, label_semantics, client_event_id, context
  ) values (
    actor_id, p_target_assertion_id, 'restore', 'positive_reversal', p_client_event_id,
    jsonb_build_object('surface', p_surface_name)
  ) returning id into event_id;

  insert into semantic_private.assertion_preferences (
    assertion_id, user_id, display_state, last_feedback_event_id
  ) values (
    p_target_assertion_id, actor_id, 'default', event_id
  )
  on conflict (assertion_id, user_id) do update
  set display_state = 'default',
      last_feedback_event_id = excluded.last_feedback_event_id,
      updated_at = now();

  update semantic_private.user_suppressions
  set active = false, lifted_by_feedback_event_id = event_id, lifted_at = now()
  where user_id = actor_id
    and predicate_key = assertion_row.predicate_key
    and surface = p_surface_name
    and active
    and (
      (assertion_row.concept_id is not null and concept_id = assertion_row.concept_id) or
      (assertion_row.user_term_id is not null and user_term_id = assertion_row.user_term_id)
    );

  return event_id;
end;
$$;

create or replace function api.confirm_assertion(
  p_target_assertion_id uuid,
  p_client_event_id uuid,
  p_exposure_id uuid,
  p_surface_name text default 'memories'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  assertion_row semantic_private.user_assertions%rowtype;
  exposure_row semantic_private.assertion_exposures%rowtype;
  existing_event semantic_private.feedback_events%rowtype;
  event_id uuid;
begin
  if actor_id is null then raise exception 'authentication required'; end if;
  perform semantic_private.assert_surface_allowed(p_surface_name);
  perform semantic_private.lock_user_state(actor_id);
  select * into assertion_row
  from semantic_private.user_assertions
  where id = p_target_assertion_id and user_id = actor_id
  for update;
  if not found then raise exception 'assertion not found'; end if;

  select * into existing_event
  from semantic_private.feedback_events
  where user_id = actor_id and client_event_id = p_client_event_id;
  if found then
    if existing_event.assertion_id <> p_target_assertion_id
       or existing_event.action <> 'confirm'
       or existing_event.exposure_id is distinct from p_exposure_id
       or existing_event.context->>'surface' is distinct from p_surface_name then
      raise exception 'client_event_id already used for another action';
    end if;
    return existing_event.id;
  end if;

  select * into exposure_row
  from semantic_private.assertion_exposures
  where id = p_exposure_id
    and user_id = actor_id
    and assertion_id = p_target_assertion_id
    and surface = p_surface_name;
  if not found then
    raise exception 'matching assertion exposure is required';
  end if;

  insert into semantic_private.feedback_events (
    user_id, assertion_id, action, label_semantics, client_event_id,
    exposure_id, ontology_version_id, assertion_score_version_id,
    presentation_version, context
  ) values (
    actor_id, p_target_assertion_id, 'confirm', 'explicit_positive', p_client_event_id,
    exposure_row.id, exposure_row.ontology_version_id,
    exposure_row.assertion_score_version_id, exposure_row.presentation_version,
    jsonb_build_object('surface', p_surface_name)
  ) returning id into event_id;

  insert into semantic_private.assertion_preferences (
    assertion_id, user_id, display_state, last_feedback_event_id
  ) values (
    p_target_assertion_id, actor_id, 'confirmed', event_id
  )
  on conflict (assertion_id, user_id) do update
  set display_state = 'confirmed',
      last_feedback_event_id = excluded.last_feedback_event_id,
      updated_at = now();

  update semantic_private.user_suppressions
  set active = false, lifted_by_feedback_event_id = event_id, lifted_at = now()
  where user_id = actor_id
    and predicate_key = assertion_row.predicate_key
    and surface = p_surface_name
    and active
    and (
      (assertion_row.concept_id is not null and concept_id = assertion_row.concept_id) or
      (assertion_row.user_term_id is not null and user_term_id = assertion_row.user_term_id)
    );

  return event_id;
end;
$$;

create or replace function api.add_assertion(
  p_client_event_id uuid,
  p_target_concept_id uuid default null,
  p_new_label text default null,
  p_linked_observation_ids uuid[] default '{}'::uuid[],
  p_surface_name text default 'memories'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  existing_event semantic_private.feedback_events%rowtype;
  v_assertion_id uuid;
  v_user_term_id uuid;
  v_event_id uuid;
  v_clean_label text;
  v_version_id uuid;
begin
  if actor_id is null then raise exception 'authentication required'; end if;
  perform semantic_private.assert_surface_allowed(p_surface_name);
  perform semantic_private.lock_user_state(actor_id);
  if num_nonnulls(p_target_concept_id, nullif(btrim(p_new_label), '')) <> 1 then
    raise exception 'provide exactly one existing concept or new label';
  end if;

  select * into existing_event
  from semantic_private.feedback_events
  where user_id = actor_id and client_event_id = p_client_event_id;
  if found then
    if existing_event.action <> 'explicit_add'
       or existing_event.context->>'surface' is distinct from p_surface_name then
      raise exception 'client_event_id already used for another action';
    end if;
    return existing_event.assertion_id;
  end if;

  select id into v_version_id
  from ontology.versions
  where status = 'published';
  if v_version_id is null then
    raise exception 'no published ontology version';
  end if;

  if p_target_concept_id is not null then
    if not exists (
      select 1
      from ontology.concept_revisions as revision
      where revision.ontology_version_id = v_version_id
        and revision.concept_id = p_target_concept_id
        and revision.status = 'active'
        and revision.sensitivity <> 'sensitive'
        and revision.inference_policy <> 'prohibited'
    ) then
      raise exception 'concept is unavailable for generic addition';
    end if;
  else
    v_clean_label := btrim(p_new_label);
    if char_length(v_clean_label) not between 1 and 160 then
      raise exception 'new label must contain 1 to 160 characters';
    end if;
    insert into semantic_private.user_terms (user_id, label, normalized_label)
    values (actor_id, v_clean_label, lower(v_clean_label))
    on conflict (user_id, normalized_label) do update
    set label = excluded.label
    returning id into v_user_term_id;
  end if;

  if p_target_concept_id is not null then
    insert into semantic_private.user_assertions (
      user_id, predicate_key, concept_id, user_term_id,
      created_ontology_version_id, assertion_origin, machine_state
    ) values (
      actor_id, 'affinity_to', p_target_concept_id, null,
      v_version_id, 'explicit_addition', 'eligible'
    )
    on conflict (user_id, predicate_key, concept_id)
      where concept_id is not null
    do update set
      created_ontology_version_id = excluded.created_ontology_version_id,
      assertion_origin = 'explicit_addition',
      source_semantic_run_id = null,
      machine_state = 'eligible',
      updated_at = now()
    returning id into v_assertion_id;
  else
    insert into semantic_private.user_assertions (
      user_id, predicate_key, concept_id, user_term_id,
      created_ontology_version_id, assertion_origin, machine_state
    ) values (
      actor_id, 'affinity_to', null, v_user_term_id,
      v_version_id, 'explicit_addition', 'eligible'
    )
    on conflict (user_id, predicate_key, user_term_id)
      where user_term_id is not null
    do update set
      created_ontology_version_id = excluded.created_ontology_version_id,
      assertion_origin = 'explicit_addition',
      source_semantic_run_id = null,
      machine_state = 'eligible',
      updated_at = now()
    returning id into v_assertion_id;
  end if;

  insert into semantic_private.feedback_events (
    user_id, assertion_id, action, label_semantics, client_event_id,
    ontology_version_id, context
  ) values (
    actor_id, v_assertion_id, 'explicit_add', 'explicit_positive', p_client_event_id,
    v_version_id,
    jsonb_build_object('surface', p_surface_name, 'linked_observation_count', cardinality(p_linked_observation_ids))
  ) returning id into v_event_id;

  insert into semantic_private.assertion_preferences (
    assertion_id, user_id, display_state, last_feedback_event_id
  ) values (v_assertion_id, actor_id, 'confirmed', v_event_id)
  on conflict (assertion_id, user_id) do update
  set display_state = 'confirmed',
      last_feedback_event_id = excluded.last_feedback_event_id,
      updated_at = now();

  if p_target_concept_id is not null and cardinality(p_linked_observation_ids) > 0 then
    if exists (
      select 1
      from unnest(p_linked_observation_ids) as requested(observation_id)
      left join semantic_private.observations as observation
        on observation.id = requested.observation_id
       and observation.user_id = actor_id
       and observation.lifecycle_state = 'active'
      where observation.id is null
    ) then
      raise exception 'linked observation not found or inactive';
    end if;

    insert into semantic_private.mapping_feedback_labels (
      feedback_event_id, user_id, observation_id, concept_id, label
    )
    select v_event_id, actor_id, distinct_id, p_target_concept_id, 'explicit_positive'
    from (select distinct unnest(p_linked_observation_ids) as distinct_id) as ids;
  end if;

  update semantic_private.user_suppressions as suppression
  set active = false, lifted_by_feedback_event_id = v_event_id, lifted_at = now()
  where suppression.user_id = actor_id
    and suppression.predicate_key = 'affinity_to'
    and suppression.surface = p_surface_name
    and suppression.active
    and (
      (p_target_concept_id is not null and suppression.concept_id = p_target_concept_id) or
      (v_user_term_id is not null and suppression.user_term_id = v_user_term_id)
    );

  return v_assertion_id;
end;
$$;

revoke all on function api.list_assertions() from public;
revoke all on function api.record_assertion_exposure(uuid, uuid, text, text, integer, text) from public;
revoke all on function api.suppress_assertion(uuid, uuid, uuid, text) from public;
revoke all on function api.restore_assertion(uuid, uuid, text) from public;
revoke all on function api.confirm_assertion(uuid, uuid, uuid, text) from public;
revoke all on function api.add_assertion(uuid, uuid, text, uuid[], text) from public;

grant usage on schema api to authenticated;
grant execute on function api.list_assertions() to authenticated;
grant execute on function api.record_assertion_exposure(uuid, uuid, text, text, integer, text) to authenticated;
grant execute on function api.suppress_assertion(uuid, uuid, uuid, text) to authenticated;
grant execute on function api.restore_assertion(uuid, uuid, text) to authenticated;
grant execute on function api.confirm_assertion(uuid, uuid, uuid, text) to authenticated;
grant execute on function api.add_assertion(uuid, uuid, text, uuid[], text) to authenticated;

commit;
