-- The semantic contract's foundation, adapted from the v0.3.1 package's
-- `sql/001_schema.sql`.
--
-- **Every `private` in the reference chain is `semantic_private` here, and that
-- translation is the whole reason this file is hand-adapted rather than
-- copied.** The reference uses `private` for its own semantic objects. This app
-- already owns that schema: `push_config`, `notify`, and `collaborators`
-- (`0041`). Applied unadapted, the reference reaches all three.
--
-- **The danger is the grant, not the revoke** — worth stating because the
-- obvious reading is the wrong one, and this comment carried it for a while.
-- Reference `001` line 12 revokes `service_role`'s usage on `private`, and
-- measured against a faithfully replayed schema `service_role` never had it:
-- `svc_schema_usage` is false on a clean install. Push works regardless,
-- because `private.notify` is `security definer` and runs as its owner, so it
-- needs no grant to read `push_config`.
--
-- What does bite is reference `002` lines 939-941, which **grant**
-- `service_role` usage on the schema and `select, insert, update` on every
-- table in it. That widens access to the table holding the shared push secret,
-- which `0020` deliberately closed with
-- `revoke all on private.push_config from public, anon, authenticated`, and to
-- the collaborator registry `0041` put in a schema precisely so no role could
-- reach it. The integration plan's own failure condition is "an adapted grant
-- broadens access". `alter default privileges in schema private` would have
-- changed the app's future objects on top of that.
--
-- So: **nothing here creates, drops, revokes on, or alters default privileges
-- for `private`.** That is an assertion to test rather than an intention —
-- compare `information_schema.role_table_grants` for `private.push_config` and
-- `private.collaborators` before and after, and confirm a real push still
-- signs, which only `net._http_response` can tell you.
--
-- One bare `private` survives below and is correct: the `sensitivity` check
-- constraint takes the *value* `'private'`, which is a sensitivity level and
-- not a schema.
--
-- **Ships no product behaviour.** Phase 0 of the integration plan installs the
-- schema and proves it upgrades cleanly; no Swift reads any of this, and
-- `Ontology.swift`, `discovery_cards` and `seed_icebreaker` all keep working
-- exactly as they do today.
--
-- Adapted against package v0.3.1, app commit 8203353, migration head 0041.

begin;

create schema if not exists extensions;
create schema if not exists ontology;
create schema if not exists semantic_private;
create schema if not exists api;

-- Supabase projects created under older defaults can automatically grant Data
-- API roles access to newly-created objects. Make every future internal object
-- opt-in, including objects added by later migrations.
revoke all on schema ontology from public, anon, authenticated, service_role;
revoke all on schema semantic_private from public, anon, authenticated, service_role;
revoke all on schema api from public, anon, authenticated, service_role;

alter default privileges in schema ontology
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges in schema ontology
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges in schema ontology
  revoke execute on functions from public, service_role;
alter default privileges in schema semantic_private
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges in schema semantic_private
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges in schema semantic_private
  revoke execute on functions from public, service_role;
alter default privileges in schema api
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges in schema api
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges in schema api
  revoke execute on functions from public, service_role;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists vector with schema extensions;
create extension if not exists pg_trgm with schema extensions;

comment on schema ontology is
  'Curated, versioned semantic graph. Do not expose through the Data API.';
comment on schema semantic_private is
  'User evidence and worker state. Do not expose through the Data API.';
comment on schema api is
  'Minimal authenticated RPC surface for the Written clients.';

create or replace function ontology.stable_uuid(value text)
returns uuid
language sql
immutable
strict
set search_path = ''
as $$
  select (
    substr(md5(value), 1, 8) || '-' ||
    substr(md5(value), 9, 4) || '-' ||
    '5' || substr(md5(value), 14, 3) || '-' ||
    'a' || substr(md5(value), 18, 3) || '-' ||
    substr(md5(value), 21, 12)
  )::uuid;
$$;

create or replace function semantic_private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- -------------------------------------------------------------------------
-- Versioned ontology
-- -------------------------------------------------------------------------

create table ontology.versions (
  id uuid primary key,
  version text not null unique,
  parent_version_id uuid references ontology.versions(id) on delete restrict,
  status text not null check (status in ('draft', 'published', 'retired')),
  description text,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  check (
    (status = 'draft' and published_at is null) or
    (status in ('published', 'retired') and published_at is not null)
  )
);

create unique index one_published_ontology_version
  on ontology.versions ((status)) where status = 'published';

create table ontology.concepts (
  id uuid primary key,
  concept_key text not null unique,
  created_at timestamptz not null default now(),
  retired_at timestamptz
);

create table ontology.concept_revisions (
  ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  concept_id uuid not null references ontology.concepts(id) on delete restrict,
  preferred_label text not null,
  concept_kind text not null check (concept_kind in (
    'hub', 'topic', 'genre', 'work', 'creator', 'activity', 'sport', 'event',
    'place', 'culture', 'language', 'cuisine', 'organization', 'medium',
    'affinity', 'identity', 'routine', 'quantitative_feature'
  )),
  definition text,
  sensitivity text not null check (sensitivity in ('ordinary', 'private', 'sensitive')),
  inference_policy text not null check (inference_policy in (
    'inferable', 'review_required', 'explicit_only', 'prohibited'
  )),
  status text not null check (status in ('draft', 'active', 'deprecated', 'blocked')),
  metadata jsonb not null default '{}'::jsonb,
  primary key (ontology_version_id, concept_id)
);

create table ontology.concept_labels (
  id uuid primary key default extensions.gen_random_uuid(),
  ontology_version_id uuid not null,
  concept_id uuid not null,
  label text not null,
  normalized_label text not null,
  locale text not null default 'und',
  label_type text not null check (label_type in (
    'preferred', 'alternate', 'hidden', 'source_term', 'related_label'
  )),
  provenance_type text not null check (provenance_type in (
    'curated', 'provider', 'external', 'user_aggregate', 'learned'
  )),
  confidence double precision not null check (confidence between 0 and 1),
  status text not null check (status in ('candidate', 'active', 'rejected', 'deprecated')),
  external_ref jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (ontology_version_id, concept_id, locale, normalized_label, label_type)
);

create index concept_labels_lookup_idx
  on ontology.concept_labels (ontology_version_id, locale, normalized_label)
  where status = 'active';
create index concept_labels_trgm_idx
  on ontology.concept_labels using gin (normalized_label extensions.gin_trgm_ops)
  where status = 'active';

create table ontology.relation_types (
  predicate_key text primary key,
  relation_class text not null check (relation_class in (
    'hierarchical', 'associative', 'descriptive', 'observed_action', 'user_claim'
  )),
  inverse_predicate_key text,
  is_symmetric boolean not null default false,
  transitive_for_inference boolean not null default false,
  max_inference_hops smallint not null default 1 check (max_inference_hops between 0 and 3),
  assertion_safe boolean not null default false,
  description text,
  foreign key (inverse_predicate_key)
    references ontology.relation_types(predicate_key)
    on delete restrict deferrable initially deferred,
  check (not is_symmetric or inverse_predicate_key = predicate_key)
);

create table ontology.concept_edges (
  id uuid primary key default extensions.gen_random_uuid(),
  ontology_version_id uuid not null,
  subject_concept_id uuid not null,
  predicate_key text not null references ontology.relation_types(predicate_key) on delete restrict,
  object_concept_id uuid not null,
  confidence double precision not null check (confidence between 0 and 1),
  provenance_type text not null check (provenance_type in (
    'curated', 'provider', 'external', 'learned', 'migration'
  )),
  provenance jsonb not null default '{}'::jsonb,
  status text not null check (status in ('candidate', 'active', 'rejected', 'blocked')),
  created_at timestamptz not null default now(),
  check (subject_concept_id <> object_concept_id),
  foreign key (ontology_version_id, subject_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (ontology_version_id, object_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (
    ontology_version_id,
    subject_concept_id,
    predicate_key,
    object_concept_id,
    provenance_type
  )
);

create index concept_edges_forward_idx
  on ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key)
  where status = 'active';
create index concept_edges_reverse_idx
  on ontology.concept_edges (ontology_version_id, object_concept_id, predicate_key)
  where status = 'active';

create table ontology.external_entities (
  id uuid primary key default extensions.gen_random_uuid(),
  provider text not null,
  external_id text not null,
  canonical_url text,
  label text not null,
  description text,
  entity_kind text,
  raw_payload jsonb not null,
  payload_hash text not null,
  license_code text,
  retrieved_at timestamptz not null,
  expires_at timestamptz,
  unique (provider, external_id, payload_hash)
);

create table ontology.external_concept_links (
  id uuid primary key default extensions.gen_random_uuid(),
  ontology_version_id uuid not null,
  concept_id uuid not null,
  external_entity_id uuid not null references ontology.external_entities(id) on delete restrict,
  link_type text not null check (link_type in ('same_as', 'close_match', 'related')),
  confidence double precision not null check (confidence between 0 and 1),
  status text not null check (status in ('candidate', 'active', 'rejected')),
  created_at timestamptz not null default now(),
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (ontology_version_id, concept_id, external_entity_id, link_type)
);

create table ontology.edge_proposals (
  id uuid primary key default extensions.gen_random_uuid(),
  base_ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  subject_concept_id uuid not null references ontology.concepts(id) on delete restrict,
  predicate_key text not null references ontology.relation_types(predicate_key) on delete restrict,
  object_concept_id uuid not null references ontology.concepts(id) on delete restrict,
  proposed_by text not null check (proposed_by in ('external_provider', 'term_miner', 'curator')),
  distinct_user_support integer not null default 0 check (distinct_user_support >= 0),
  independent_channel_support integer not null default 0 check (independent_channel_support >= 0),
  bootstrap_stability double precision check (bootstrap_stability between 0 and 1),
  confidence double precision not null check (confidence between 0 and 1),
  provenance jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  check (subject_concept_id <> object_concept_id)
);

create table ontology.embedding_models (
  id uuid primary key,
  model_key text not null unique,
  dimensions integer not null check (dimensions > 0),
  revision text not null,
  status text not null check (status in ('draft', 'active', 'retired')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- V0 pins one 384-dimensional candidate-generation representation. A future
-- model with another dimension gets a separate table/migration; old vectors
-- are not overwritten.
create table ontology.concept_embeddings_384 (
  ontology_version_id uuid not null,
  concept_id uuid not null,
  embedding_model_id uuid not null references ontology.embedding_models(id) on delete restrict,
  embedding extensions.vector(384) not null,
  content_hash text not null,
  created_at timestamptz not null default now(),
  primary key (ontology_version_id, concept_id, embedding_model_id),
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict
);

create index concept_embeddings_384_hnsw_idx
  on ontology.concept_embeddings_384
  using hnsw (embedding extensions.vector_cosine_ops);

create table ontology.model_versions (
  id uuid primary key,
  model_key text not null,
  version text not null,
  model_role text not null check (model_role in (
    'extractor', 'resolver', 'scorer', 'surfacing', 'term_miner'
  )),
  code_hash text,
  parameters jsonb not null default '{}'::jsonb,
  status text not null check (status in ('draft', 'active', 'retired')),
  created_at timestamptz not null default now(),
  unique (model_key, version)
);

create table ontology.motif_rules (
  id uuid primary key,
  ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  rule_key text not null,
  evidence_target_concept_id uuid not null,
  output_concept_id uuid not null,
  evidence_predicate_key text not null
    references ontology.relation_types(predicate_key) on delete restrict,
  output_predicate_key text not null
    references ontology.relation_types(predicate_key) on delete restrict,
  rule_kind text not null check (rule_kind in (
    'shared_target_convergence', 'explicit_component_set'
  )),
  minimum_independence_groups smallint not null check (minimum_independence_groups >= 2),
  minimum_strength double precision not null check (minimum_strength between 0 and 1),
  configuration jsonb not null,
  status text not null check (status in ('draft', 'active', 'retired')),
  created_at timestamptz not null default now(),
  foreign key (ontology_version_id, evidence_target_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (ontology_version_id, output_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (id, ontology_version_id),
  unique (
    id, ontology_version_id, evidence_target_concept_id, output_concept_id
  ),
  unique (ontology_version_id, rule_key)
);

-- -------------------------------------------------------------------------
-- Source catalog and user-owned evidence
-- -------------------------------------------------------------------------

create table semantic_private.sources (
  source_code text primary key,
  provider text not null,
  evidence_channel text not null,
  independence_group text not null,
  online_resolution_policy text not null check (online_resolution_policy in (
    'catalog_ids_only', 'public_metadata_only', 'disabled_private', 'not_applicable'
  )),
  default_reliability double precision not null check (default_reliability between 0 and 1),
  action_weights jsonb not null default '{}'::jsonb,
  active boolean not null default true
);

create table semantic_private.source_connections (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  connection_state text not null check (connection_state in (
    'connected', 'revoked', 'permission_denied', 'error'
  )),
  granted_scopes text[] not null default '{}',
  connected_at timestamptz,
  revoked_at timestamptz,
  last_ingested_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, source_code)
);

create trigger source_connections_set_updated_at
before update on semantic_private.source_connections
for each row execute function semantic_private.set_updated_at();

create table semantic_private.source_coverage (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  coverage_state text not null check (coverage_state in (
    'usable', 'observed_empty', 'permission_denied', 'not_connected',
    'unsupported', 'error', 'stale', 'revoked'
  )),
  observation_count integer not null default 0 check (observation_count >= 0),
  window_start timestamptz,
  window_end timestamptz,
  measured_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb
);

create index source_coverage_user_source_idx
  on semantic_private.source_coverage (user_id, source_code, measured_at desc);

create table semantic_private.ingestion_runs (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  connector_version text not null,
  input_hash text not null,
  status text not null check (status in ('running', 'succeeded', 'failed', 'superseded')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  metrics jsonb not null default '{}'::jsonb,
  error_code text,
  check (
    (status = 'running' and finished_at is null) or
    (status <> 'running' and finished_at is not null)
  ),
  unique (id, user_id),
  unique (id, user_id, source_code)
);

create unique index ingestion_run_live_identity_idx
  on semantic_private.ingestion_runs (
    user_id, source_code, input_hash, connector_version
  )
  where status in ('running', 'succeeded');

create table semantic_private.observations (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ingestion_run_id uuid not null,
  source_code text not null references semantic_private.sources(source_code) on delete restrict,
  data_type text not null,
  observation_kind text not null,
  action_type text not null,
  occurred_at timestamptz,
  ingested_at timestamptz not null default now(),
  source_item_hmac text not null,
  record_fingerprint text not null,
  content_lineage_hmac text,
  session_hmac text,
  payload_schema_version text not null,
  normalized_payload jsonb not null,
  raw_blob_ref text,
  field_quality double precision not null default 1 check (field_quality between 0 and 1),
  action_weight double precision not null default 1 check (action_weight between 0 and 1),
  privacy_class text not null check (privacy_class in (
    'public_catalog', 'private_text', 'sensitive', 'quantitative'
  )),
  allow_external_resolution boolean not null default false,
  lifecycle_state text not null default 'active' check (lifecycle_state in (
    'active', 'excluded', 'deleted'
  )),
  exclusion_code text,
  excluded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, source_code, record_fingerprint),
  foreign key (ingestion_run_id, user_id, source_code)
    references semantic_private.ingestion_runs(id, user_id, source_code)
    on delete no action deferrable initially deferred
);

create index observations_user_source_time_idx
  on semantic_private.observations (user_id, source_code, occurred_at desc);
create index observations_lineage_idx
  on semantic_private.observations (user_id, content_lineage_hmac)
  where content_lineage_hmac is not null and lifecycle_state = 'active';

create or replace function semantic_private.guard_observation_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.ingestion_run_id is distinct from old.ingestion_run_id
     or new.source_code is distinct from old.source_code
     or new.data_type is distinct from old.data_type
     or new.observation_kind is distinct from old.observation_kind
     or new.action_type is distinct from old.action_type
     or new.occurred_at is distinct from old.occurred_at
     or new.ingested_at is distinct from old.ingested_at
     or new.source_item_hmac is distinct from old.source_item_hmac
     or new.record_fingerprint is distinct from old.record_fingerprint
     or new.content_lineage_hmac is distinct from old.content_lineage_hmac
     or new.session_hmac is distinct from old.session_hmac
     or new.payload_schema_version is distinct from old.payload_schema_version
     or new.normalized_payload is distinct from old.normalized_payload
     or new.raw_blob_ref is distinct from old.raw_blob_ref
     or new.field_quality is distinct from old.field_quality
     or new.action_weight is distinct from old.action_weight
     or new.privacy_class is distinct from old.privacy_class
     or new.allow_external_resolution is distinct from old.allow_external_resolution
     or new.created_at is distinct from old.created_at
  then
    raise exception 'observation evidence is append-only';
  end if;
  return new;
end;
$$;

create trigger observations_guard_immutable
before update on semantic_private.observations
for each row execute function semantic_private.guard_observation_immutable();

create table semantic_private.observation_mentions (
  id uuid primary key default extensions.gen_random_uuid(),
  observation_id uuid not null,
  user_id uuid not null,
  mention_text text not null,
  normalized_text text not null,
  mention_role text not null,
  locale text not null default 'und',
  type_hint text,
  source_field text not null,
  extraction_method text not null,
  extractor_model_id uuid references ontology.model_versions(id) on delete restrict,
  confidence double precision not null check (confidence between 0 and 1),
  safe_for_global_mining boolean not null default false,
  safe_for_external_resolution boolean not null default false,
  created_at timestamptz not null default now(),
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade
);

create index observation_mentions_observation_idx
  on semantic_private.observation_mentions (observation_id);
create index observation_mentions_normalized_idx
  on semantic_private.observation_mentions (normalized_text)
  where safe_for_global_mining;

create table semantic_private.semantic_runs (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  resolver_model_id uuid not null references ontology.model_versions(id) on delete restrict,
  scorer_model_id uuid not null references ontology.model_versions(id) on delete restrict,
  embedding_model_id uuid references ontology.embedding_models(id) on delete restrict,
  input_revision bigint not null,
  input_hash text not null,
  status text not null check (status in ('running', 'succeeded', 'failed', 'stale')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  metrics jsonb not null default '{}'::jsonb,
  error_code text,
  check (
    (status = 'running' and finished_at is null) or
    (status <> 'running' and finished_at is not null)
  ),
  unique (id, user_id),
  unique (id, user_id, ontology_version_id),
  check (input_revision >= 0)
);

create unique index semantic_run_live_identity_idx
  on semantic_private.semantic_runs (
    user_id, ontology_version_id, resolver_model_id, scorer_model_id,
    input_revision, input_hash
  )
  where status in ('running', 'succeeded');

create table semantic_private.observation_mappings (
  id uuid primary key default extensions.gen_random_uuid(),
  semantic_run_id uuid not null,
  observation_id uuid not null,
  user_id uuid not null,
  ontology_version_id uuid not null,
  concept_id uuid not null,
  mapping_method text not null check (mapping_method in (
    'provider_id', 'curated_alias', 'provider_metadata', 'lexical',
    'embedding_candidate', 'external_candidate', 'graph_context', 'user_correction'
  )),
  mapping_state text not null check (mapping_state in (
    'candidate', 'accepted', 'rejected', 'superseded'
  )),
  confidence double precision not null check (confidence between 0 and 1),
  candidate_rank integer not null check (candidate_rank > 0),
  score_margin double precision,
  feature_snapshot jsonb not null,
  evidence_path jsonb not null,
  created_at timestamptz not null default now(),
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade,
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete cascade,
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (id, user_id),
  unique (id, user_id, semantic_run_id),
  unique (semantic_run_id, observation_id, concept_id, mapping_method)
);

create index observation_mappings_observation_idx
  on semantic_private.observation_mappings (observation_id, semantic_run_id);
create index observation_mappings_user_concept_idx
  on semantic_private.observation_mappings (user_id, concept_id)
  where mapping_state = 'accepted';

create table semantic_private.concept_source_scores (
  id uuid primary key default extensions.gen_random_uuid(),
  semantic_run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null,
  concept_id uuid not null,
  evidence_channel text not null,
  independence_group text not null,
  strength double precision not null check (strength between 0 and 1),
  confidence double precision not null check (confidence between 0 and 1),
  unique_lineage_count integer not null check (unique_lineage_count >= 0),
  evidence_count integer not null check (evidence_count >= 0),
  created_at timestamptz not null default now(),
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete cascade,
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (semantic_run_id, concept_id, evidence_channel)
);

create table semantic_private.concept_scores (
  id uuid primary key default extensions.gen_random_uuid(),
  semantic_run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null,
  concept_id uuid not null,
  strength double precision not null check (strength between 0 and 1),
  confidence double precision not null check (confidence between 0 and 1),
  independent_source_breadth integer not null check (independent_source_breadth >= 0),
  stability double precision not null check (stability between 0 and 1),
  usable_source_count integer not null check (usable_source_count >= 0),
  missing_source_count integer not null check (missing_source_count >= 0),
  explanation jsonb not null,
  created_at timestamptz not null default now(),
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete cascade,
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (semantic_run_id, concept_id)
);

create index concept_scores_user_concept_idx
  on semantic_private.concept_scores (user_id, concept_id, created_at desc);

create table semantic_private.motif_instances (
  id uuid primary key default extensions.gen_random_uuid(),
  semantic_run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null,
  motif_rule_id uuid not null,
  evidence_target_concept_id uuid not null,
  output_concept_id uuid not null,
  strength double precision not null check (strength between 0 and 1),
  confidence double precision not null check (confidence between 0 and 1),
  breadth integer not null check (breadth >= 0),
  stability double precision not null check (stability between 0 and 1),
  explanation jsonb not null,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (id, user_id, semantic_run_id),
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete cascade,
  foreign key (
    motif_rule_id, ontology_version_id,
    evidence_target_concept_id, output_concept_id
  ) references ontology.motif_rules(
    id, ontology_version_id,
    evidence_target_concept_id, output_concept_id
  )
    on delete restrict,
  foreign key (ontology_version_id, evidence_target_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (ontology_version_id, output_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  unique (
    semantic_run_id, motif_rule_id, evidence_target_concept_id,
    output_concept_id
  )
);

create table semantic_private.motif_support (
  motif_instance_id uuid not null,
  observation_mapping_id uuid not null,
  semantic_run_id uuid not null,
  user_id uuid not null,
  contribution double precision not null check (contribution between 0 and 1),
  independence_group text not null,
  evidence_path jsonb not null default '{}'::jsonb,
  primary key (motif_instance_id, observation_mapping_id),
  foreign key (motif_instance_id, user_id, semantic_run_id)
    references semantic_private.motif_instances(id, user_id, semantic_run_id)
    on delete cascade,
  foreign key (observation_mapping_id, user_id, semantic_run_id)
    references semantic_private.observation_mappings(id, user_id, semantic_run_id)
    on delete cascade
);

-- -------------------------------------------------------------------------
-- User assertions and feedback
-- -------------------------------------------------------------------------

create table semantic_private.user_terms (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null check (char_length(label) between 1 and 160),
  normalized_label text not null,
  proposed_concept_id uuid references ontology.concepts(id) on delete restrict,
  mapping_state text not null default 'unresolved' check (mapping_state in (
    'unresolved', 'candidate', 'user_confirmed', 'rejected'
  )),
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, normalized_label)
);

create table semantic_private.user_assertions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  predicate_key text not null references ontology.relation_types(predicate_key) on delete restrict,
  concept_id uuid references ontology.concepts(id) on delete restrict,
  user_term_id uuid,
  created_ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  source_semantic_run_id uuid,
  assertion_origin text not null check (assertion_origin in (
    'inferred', 'explicit_addition', 'explicit_self_report'
  )),
  machine_state text not null check (machine_state in (
    'candidate', 'eligible', 'inactive', 'expired'
  )),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  check (num_nonnulls(concept_id, user_term_id) = 1),
  check (
    (assertion_origin = 'inferred' and source_semantic_run_id is not null) or
    (assertion_origin <> 'inferred' and source_semantic_run_id is null)
  ),
  foreign key (user_term_id, user_id)
    references semantic_private.user_terms(id, user_id)
    on delete no action deferrable initially deferred,
  foreign key (created_ontology_version_id, concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (
    source_semantic_run_id, user_id, created_ontology_version_id
  ) references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete no action deferrable initially deferred
);

create index user_assertions_user_idx
  on semantic_private.user_assertions (user_id, updated_at desc);
create unique index user_assertion_concept_identity_idx
  on semantic_private.user_assertions (user_id, predicate_key, concept_id)
  where concept_id is not null;
create unique index user_assertion_term_identity_idx
  on semantic_private.user_assertions (user_id, predicate_key, user_term_id)
  where user_term_id is not null;

create trigger user_assertions_set_updated_at
before update on semantic_private.user_assertions
for each row execute function semantic_private.set_updated_at();

create table semantic_private.assertion_score_versions (
  id uuid primary key default extensions.gen_random_uuid(),
  assertion_id uuid not null,
  user_id uuid not null,
  semantic_run_id uuid not null,
  ontology_version_id uuid not null,
  motif_instance_id uuid,
  strength double precision not null check (strength between 0 and 1),
  confidence double precision not null check (confidence between 0 and 1),
  breadth integer not null check (breadth >= 0),
  stability double precision not null check (stability between 0 and 1),
  surfacing_score double precision not null check (surfacing_score between 0 and 1),
  display_payload jsonb not null,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (id, user_id, assertion_id),
  unique (id, user_id, semantic_run_id),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete no action deferrable initially deferred,
  foreign key (motif_instance_id, user_id, semantic_run_id)
    references semantic_private.motif_instances(id, user_id, semantic_run_id)
    on delete no action deferrable initially deferred,
  unique (assertion_id, semantic_run_id)
);

-- Only an exact-revision finalized semantic run can advance this pointer.
-- Worker output tables remain historical and are never selected merely because
-- their created_at is newest.
create table semantic_private.assertion_current_scores (
  assertion_id uuid not null,
  user_id uuid not null,
  assertion_score_version_id uuid not null,
  semantic_run_id uuid not null,
  finalized_at timestamptz not null default now(),
  primary key (assertion_id, user_id),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (
    assertion_score_version_id, user_id, assertion_id
  ) references semantic_private.assertion_score_versions(id, user_id, assertion_id)
    on delete cascade,
  foreign key (
    assertion_score_version_id, user_id, semantic_run_id
  ) references semantic_private.assertion_score_versions(id, user_id, semantic_run_id)
    on delete cascade
);

create table semantic_private.assertion_evidence (
  assertion_score_version_id uuid not null,
  user_id uuid not null,
  observation_mapping_id uuid not null,
  contribution double precision not null check (contribution between 0 and 1),
  independence_group text not null,
  evidence_path jsonb not null,
  primary key (assertion_score_version_id, observation_mapping_id),
  foreign key (assertion_score_version_id, user_id)
    references semantic_private.assertion_score_versions(id, user_id) on delete cascade,
  foreign key (observation_mapping_id, user_id)
    references semantic_private.observation_mappings(id, user_id) on delete cascade
);

create table semantic_private.assertion_exposures (
  id uuid primary key default extensions.gen_random_uuid(),
  assertion_id uuid not null,
  user_id uuid not null,
  assertion_score_version_id uuid,
  ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  surface text not null,
  presentation_version text not null,
  displayed_label text not null,
  rank integer,
  exposed_at timestamptz not null default now(),
  check (surface = 'memories'),
  check (char_length(presentation_version) between 1 and 80),
  check (char_length(displayed_label) between 1 and 240),
  check (rank is null or rank >= 0),
  unique (id, user_id, assertion_id),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (assertion_score_version_id, user_id, assertion_id)
    references semantic_private.assertion_score_versions(id, user_id, assertion_id)
    on delete no action deferrable initially deferred
);

create table semantic_private.feedback_events (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  assertion_id uuid not null,
  exposure_id uuid,
  action text not null check (action in (
    'suppress', 'restore', 'confirm', 'explicit_add'
  )),
  label_semantics text not null check (label_semantics in (
    'ambiguous_rejection', 'explicit_positive', 'positive_reversal'
  )),
  client_event_id uuid not null,
  ontology_version_id uuid references ontology.versions(id) on delete restrict,
  assertion_score_version_id uuid,
  presentation_version text,
  context jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, client_event_id),
  check (not (context ? 'reason')),
  check (presentation_version is null or char_length(presentation_version) between 1 and 80),
  check (
    (action in ('suppress', 'confirm')
      and exposure_id is not null
      and ontology_version_id is not null
      and presentation_version is not null) or
    (action = 'explicit_add'
      and exposure_id is null
      and ontology_version_id is not null
      and assertion_score_version_id is null
      and presentation_version is null) or
    (action = 'restore'
      and exposure_id is null
      and ontology_version_id is null
      and assertion_score_version_id is null
      and presentation_version is null)
  ),
  check (
    (action = 'suppress' and label_semantics = 'ambiguous_rejection') or
    (action in ('confirm', 'explicit_add') and label_semantics = 'explicit_positive') or
    (action = 'restore' and label_semantics = 'positive_reversal')
  ),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id)
    on delete no action deferrable initially deferred,
  foreign key (exposure_id, user_id, assertion_id)
    references semantic_private.assertion_exposures(id, user_id, assertion_id)
    on delete no action deferrable initially deferred,
  foreign key (assertion_score_version_id, user_id, assertion_id)
    references semantic_private.assertion_score_versions(id, user_id, assertion_id)
    on delete no action deferrable initially deferred
);

create index feedback_events_user_assertion_idx
  on semantic_private.feedback_events (user_id, assertion_id, created_at desc);

create table semantic_private.assertion_preferences (
  assertion_id uuid not null,
  user_id uuid not null,
  display_state text not null check (display_state in (
    'default', 'confirmed', 'suppressed'
  )),
  last_feedback_event_id uuid,
  updated_at timestamptz not null default now(),
  primary key (assertion_id, user_id),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (last_feedback_event_id, user_id)
    references semantic_private.feedback_events(id, user_id)
    on delete no action deferrable initially deferred
);

create table semantic_private.user_suppressions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id uuid references ontology.concepts(id) on delete restrict,
  user_term_id uuid,
  predicate_key text not null references ontology.relation_types(predicate_key) on delete restrict,
  surface text not null,
  source_feedback_event_id uuid not null,
  active boolean not null default true,
  lifted_by_feedback_event_id uuid,
  created_at timestamptz not null default now(),
  lifted_at timestamptz,
  check (num_nonnulls(concept_id, user_term_id) = 1),
  check (surface = 'memories'),
  foreign key (user_term_id, user_id)
    references semantic_private.user_terms(id, user_id)
    on delete no action deferrable initially deferred,
  foreign key (source_feedback_event_id, user_id)
    references semantic_private.feedback_events(id, user_id)
    on delete no action deferrable initially deferred,
  foreign key (lifted_by_feedback_event_id, user_id)
    references semantic_private.feedback_events(id, user_id)
    on delete no action deferrable initially deferred
);

create unique index one_active_concept_suppression
  on semantic_private.user_suppressions (user_id, concept_id, predicate_key, surface)
  where active and concept_id is not null;
create unique index one_active_term_suppression
  on semantic_private.user_suppressions (user_id, user_term_id, predicate_key, surface)
  where active and user_term_id is not null;

create table semantic_private.mapping_feedback_labels (
  id uuid primary key default extensions.gen_random_uuid(),
  feedback_event_id uuid not null,
  user_id uuid not null,
  observation_id uuid not null,
  concept_id uuid not null references ontology.concepts(id) on delete restrict,
  label text not null check (label = 'explicit_positive'),
  created_at timestamptz not null default now(),
  foreign key (feedback_event_id, user_id)
    references semantic_private.feedback_events(id, user_id) on delete cascade,
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade,
  unique (feedback_event_id, observation_id, concept_id)
);

create table semantic_private.user_state_versions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0),
  updated_at timestamptz not null default now()
);

create table semantic_private.rule_feedback_stats (
  model_id uuid not null references ontology.model_versions(id) on delete restrict,
  rule_signature text not null,
  distinct_positive_users integer not null default 0 check (distinct_positive_users >= 0),
  distinct_ambiguous_rejection_users integer not null default 0
    check (distinct_ambiguous_rejection_users >= 0),
  acceptance_alpha double precision not null default 4 check (acceptance_alpha > 0),
  acceptance_beta double precision not null default 2 check (acceptance_beta > 0),
  review_state text not null default 'monitor' check (review_state in (
    'monitor', 'needs_review', 'approved', 'retired'
  )),
  updated_at timestamptz not null default now(),
  primary key (model_id, rule_signature)
);

create table semantic_private.emergent_terms (
  id uuid primary key default extensions.gen_random_uuid(),
  normalized_term text not null,
  locale text not null default 'und',
  type_hint text,
  distinct_user_count integer not null default 0 check (distinct_user_count >= 0),
  independent_channel_count integer not null default 0 check (independent_channel_count >= 0),
  occurrence_count integer not null default 0 check (occurrence_count >= 0),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  privacy_threshold_met boolean not null default false,
  status text not null default 'candidate' check (status in (
    'candidate', 'review', 'promoted', 'rejected'
  ))
);

create unique index emergent_terms_identity_idx
  on semantic_private.emergent_terms (normalized_term, locale, coalesce(type_hint, ''));

create table semantic_private.emergent_term_relations (
  id uuid primary key default extensions.gen_random_uuid(),
  left_term_id uuid not null references semantic_private.emergent_terms(id) on delete cascade,
  right_term_id uuid not null references semantic_private.emergent_terms(id) on delete cascade,
  proposal_kind text not null check (proposal_kind in ('alias', 'related')),
  lexical_similarity double precision check (lexical_similarity between 0 and 1),
  semantic_similarity double precision check (semantic_similarity between 0 and 1),
  distinct_user_support integer not null default 0 check (distinct_user_support >= 0),
  independent_channel_support integer not null default 0 check (independent_channel_support >= 0),
  external_corroboration jsonb not null default '{}'::jsonb,
  status text not null default 'candidate' check (status in (
    'candidate', 'review', 'promoted', 'rejected'
  )),
  created_at timestamptz not null default now(),
  check (left_term_id <> right_term_id),
  unique (left_term_id, right_term_id, proposal_kind)
);

-- -------------------------------------------------------------------------
-- Transactional worker queue
-- -------------------------------------------------------------------------

create table semantic_private.worker_jobs (
  id uuid primary key default extensions.gen_random_uuid(),
  job_type text not null check (job_type in (
    'map_observation', 'recompute_user', 'mine_terms', 'refresh_external_entity'
  )),
  user_id uuid references auth.users(id) on delete cascade,
  payload jsonb not null,
  idempotency_key text not null unique,
  status text not null default 'queued' check (status in (
    'queued', 'running', 'succeeded', 'failed', 'dead'
  )),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  last_error text,
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index worker_jobs_claim_idx
  on semantic_private.worker_jobs (available_at, created_at)
  where status = 'queued';

create trigger worker_jobs_set_updated_at
before update on semantic_private.worker_jobs
for each row execute function semantic_private.set_updated_at();

commit;
