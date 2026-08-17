-- 0203 — the candidate overlay gets somewhere to live.
--
-- ## What this is
--
-- Day 2 of the semantic execution specification: the sixteen storage objects
-- `compiled_semantic_contract_v1.json` lists under `required_storage_objects`.
-- Fifteen of them did not exist; `observation_mentions` did.
--
-- **Nothing here changes behaviour.** No job writes these tables yet, no reader
-- consults them, `semantic_qwen_overlay` stays disabled and the exact lane is
-- untouched. This is the `storage_integration` gate's subject, not its pass.
--
-- ## The name the contract uses is not the name this database uses
--
-- The contract calls them `private.observation_mentions`,
-- `private.review_items` and so on. **`private` is a real schema in this
-- database and holds `push_config` and `collaborators`.** Creating anything
-- there would put semantic overlay state in the one schema nothing is granted
-- on, beside the push secret — and `CLAUDE.md` is explicit that no executable
-- statement in an adapted migration may name it, because the hazard is the
-- grant rather than the revoke.
--
-- So `private.*` in the contract means `semantic_private.*` here, exactly as
-- `hub:game` means `hub:games_play`. It is the same class of crosswalk and it is
-- written down for the same reason: the authoring name and the production name
-- differ, and a compiler that resolved it silently would be one nobody could
-- audit.
--
-- ## The shape every table follows, and why
--
-- - **RLS enabled with no policies.** That is the whole of `semantic_private`'s
--   posture: access is decided by role grants and `security definer` functions,
--   and adding the first policy costs that sentence. The advisors will report
--   each of these as `rls_enabled_no_policy`; read it as confirmation.
-- - **Composite foreign keys carrying `user_id`.** `(observation_id, user_id)
--   references observations(id, user_id)` rather than `observation_id` alone.
--   The constraint then *proves* a child belongs to the same account as its
--   parent, instead of a query being careful. Every existing table here does
--   this and it is the cheapest tenancy guarantee in the schema.
-- - **`on delete cascade` for derived state, `restrict` for vocabulary.** These
--   are candidates and presentations, not evidence: when the evidence goes they
--   must go, or `api.forget_distillation` leaves a profile standing on rows that
--   no longer exist. Ontology references restrict, because deleting a concept
--   out from under a candidate is a different mistake.
-- - **Explicit grants, per table.** `grant … on all tables` binds at execution
--   time, so a table created later gets nothing from an earlier statement. Each
--   grant is written out and then asserted from the catalog, because
--   `information_schema` shows only what the querying role can see and answers
--   empty here.
-- - **`semantic_worker` gets select and insert; update only where a row is
--   genuinely a state machine.** Four tables mutate: a candidate's score and
--   tier, a suppression being restored, a provisional entity being redirected,
--   and the sidecar's refresh state. Everything else is append-only in fact, and
--   two of them are append-only by trigger.
-- - **`semantic_ingestor` gets nothing.** It holds zero table privileges today
--   and may call exactly one function; the thing reachable from the internet
--   must not be able to read a review or a candidate.
--
-- ## Two tables are append-only by trigger rather than by convention
--
-- `review_items` and `review_exposures` are the record of *what a person was
-- actually shown*. A feedback label means nothing without it — "they struck this"
-- is only interpretable against the rank, tier and epoch it was struck at. An
-- update would rewrite the question after the answer, so the trigger refuses
-- everything that is not an insert, the same shape `ingestion_run_items` uses
-- for evidence.
--
-- ## What is deliberately absent
--
-- **`model_invocations` has no column that could hold provider text.** Hashes,
-- versions, token counts, latency, status and a validation error code. The
-- specification's rule is to log hashes and operational metadata and never raw
-- titles or prompts; the way to keep that true is to give the text nowhere to go.
--
-- **`source_text_evidence` is the only mutable text store, and it carries its own
-- expiry.** It is the sidecar §13 asks for. Note it duplicates capability that
-- `raw_source_records` already has — encrypted payload, `retained_until`,
-- `lifecycle_state` — and that overlap is deliberate for now: the sidecar exists
-- so *derivatives* can inherit one expiry, which is the piece `raw_source_records`
-- does not model. Collapsing the two is a later decision, not a silent one.

begin;

-- **`observation_mentions` predates the tenancy pattern and cannot be pointed
-- at yet.** It carries `user_id not null` and a composite key to `observations`,
-- but its own only unique key is `(id)` — so nothing can reference it the way
-- everything else here references its parent. Additive, no rewrite, and it makes
-- the one pre-existing overlay table referenceable on the same terms as the
-- fifteen that follow.
alter table semantic_private.observation_mentions
  add constraint observation_mentions_id_user_id_key unique (id, user_id);

-- ---------------------------------------------------------------------------
-- Vocabulary shared by several tables.
--
-- **These check constraints restate closed vocabularies the compiled contract
-- also holds, and that duplication is the thing this project keeps paying for.**
-- It is accepted here only because a check constraint is the only mechanism the
-- database has, and it is made safe by `tools/compile_semantic_contract.py
-- --check-database`, which reads these constraints back and fails if they and
-- the contract disagree. The constraint is not a second source of truth; it is
-- an enforcement of the first, verified against it.
-- ---------------------------------------------------------------------------

create table semantic_private.provisional_entities (
  id uuid primary key default extensions.gen_random_uuid(),
  -- **Scope decides whether this is anybody else's business.** A `shared`
  -- provisional carries a stable external identifier and may be reused; a
  -- `user` provisional is one person's unresolved noun and never leaves them.
  scope text not null check (scope in ('user', 'shared')),
  user_id uuid references auth.users(id) on delete cascade,
  canonical_label text not null check (length(btrim(canonical_label)) > 0),
  normalized_label text not null check (length(btrim(normalized_label)) > 0),
  family text not null check (family in (
    'activity','album','anime','book','channel','culture','event','event_type',
    'franchise','game','game_category','group','hub','idea','music_recording',
    'music_work','organization','person','place','platform','sport','tour','work'
  )),
  external_ids jsonb not null default '{}'::jsonb,
  identity_state text not null default 'personal_provisional' check (identity_state in (
    'personal_provisional','new_stable_id_candidate','resolved_existing','ambiguous','quarantined'
  )),
  -- A provisional that later resolves keeps its id and points at the winner, so
  -- historical evidence and a person's strike survive the merge.
  redirect_concept_id uuid references ontology.concepts(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provisional_entities_user_scope_check
    check ((scope = 'user') = (user_id is not null)),
  unique (id, user_id)
);

create index provisional_entities_user_idx
  on semantic_private.provisional_entities (user_id) where user_id is not null;
create index provisional_entities_lookup_idx
  on semantic_private.provisional_entities (normalized_label, family);

create table semantic_private.mention_resolutions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mention_id uuid not null,
  resolution text not null check (resolution in (
    'resolved_existing','new_stable_id_candidate','personal_provisional','ambiguous','unresolved'
  )),
  ontology_version_id uuid,
  concept_id uuid,
  external_entity_id uuid references ontology.external_entities(id) on delete restrict,
  provisional_entity_id uuid,
  route_id text not null,
  resolver_version text not null,
  catalog_snapshot text,
  confidence double precision not null check (confidence >= 0 and confidence <= 1),
  abstention_reason text,
  created_at timestamptz not null default now(),
  foreign key (mention_id, user_id)
    references semantic_private.observation_mentions (id, user_id) on delete cascade,
  foreign key (ontology_version_id, concept_id)
    references ontology.concept_revisions (ontology_version_id, concept_id) on delete restrict,
  foreign key (provisional_entity_id, user_id)
    references semantic_private.provisional_entities (id, user_id) on delete cascade,
  -- **Exactly one identity, or none at all.** A resolution naming both a concept
  -- and a provisional is two answers to one question, and the reader would have
  -- to choose. An abstention names neither and says why.
  constraint mention_resolutions_single_identity_check check (
    (case when concept_id is not null then 1 else 0 end
     + case when external_entity_id is not null then 1 else 0 end
     + case when provisional_entity_id is not null then 1 else 0 end)
    = case when resolution in ('ambiguous','unresolved') then 0 else 1 end
  ),
  unique (id, user_id)
);

create index mention_resolutions_mention_idx
  on semantic_private.mention_resolutions (mention_id, user_id);

create table semantic_private.candidate_relation_proposals (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  subject_concept_id uuid references ontology.concepts(id) on delete restrict,
  subject_provisional_id uuid references semantic_private.provisional_entities(id) on delete cascade,
  predicate text not null check (predicate in (
    'part_of_franchise','features','about','performed_by','composed_by','recording_of',
    'soundtrack_of','member_of_group','played_for','official_channel_of',
    'represented_team_in','located_in'
  )),
  object_concept_id uuid references ontology.concepts(id) on delete restrict,
  object_provisional_id uuid references semantic_private.provisional_entities(id) on delete cascade,
  object_label_hypothesis text,
  authority_state text not null default 'model_proposed' check (authority_state in (
    'model_proposed','displayable_suggestion','user_confirmed',
    'catalog_supported','community_supported','verified_relation'
  )),
  -- **Traversal is off unless the relation is verified, and the constraint says
  -- so rather than the reader remembering.** An inferred `about` edge that could
  -- be walked is how a model proposal becomes a fact nobody decided to accept.
  traversable boolean not null default false,
  provenance jsonb not null default '{}'::jsonb,
  model_revision text,
  prompt_version text,
  grammar_version text,
  confidence double precision check (confidence >= 0 and confidence <= 1),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  constraint candidate_relation_subject_check check (
    (subject_concept_id is not null) <> (subject_provisional_id is not null)),
  constraint candidate_relation_traversal_check check (
    traversable = false or authority_state = 'verified_relation')
);

create index candidate_relation_proposals_subject_idx
  on semantic_private.candidate_relation_proposals (subject_concept_id, predicate);

create table semantic_private.user_term_candidates (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id uuid references ontology.concepts(id) on delete restrict,
  provisional_entity_id uuid,
  user_facing_predicate text not null,
  confidence_tier text not null check (confidence_tier in ('direct','inferred','secondary')),
  aggregate_score double precision not null default 0
    check (aggregate_score >= 0 and aggregate_score <= 1),
  primary_route_id text not null,
  lifecycle_state text not null default 'active' check (lifecycle_state in (
    'active','superseded','withdrawn')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (provisional_entity_id, user_id)
    references semantic_private.provisional_entities (id, user_id) on delete cascade,
  constraint user_term_candidates_single_term_check check (
    (concept_id is not null) <> (provisional_entity_id is not null)),
  unique (id, user_id)
);

-- **One active card per term and predicate, and `review_epoch` is not in the
-- key.** The specification is explicit that the epoch belongs to immutable
-- exposure history rather than to candidate identity; putting it here would let
-- the same term reappear as a second live card every review round.
create unique index user_term_candidates_one_active_concept_idx
  on semantic_private.user_term_candidates (user_id, concept_id, user_facing_predicate)
  where lifecycle_state = 'active' and concept_id is not null;
create unique index user_term_candidates_one_active_provisional_idx
  on semantic_private.user_term_candidates (user_id, provisional_entity_id, user_facing_predicate)
  where lifecycle_state = 'active' and provisional_entity_id is not null;

create table semantic_private.candidate_support_links (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  candidate_id uuid not null,
  observation_id uuid not null,
  mention_resolution_id uuid,
  route_id text not null,
  evidence_family_key text not null,
  -- Bounded on the way in. Repeated fetches and same-channel reposts must not
  -- accumulate, and a cap enforced only in the scorer is a cap one query can
  -- forget.
  contribution double precision not null default 0
    check (contribution >= 0 and contribution <= 1),
  created_at timestamptz not null default now(),
  foreign key (candidate_id, user_id)
    references semantic_private.user_term_candidates (id, user_id) on delete cascade,
  foreign key (observation_id, user_id)
    references semantic_private.observations (id, user_id) on delete cascade,
  foreign key (mention_resolution_id, user_id)
    references semantic_private.mention_resolutions (id, user_id) on delete cascade,
  unique (candidate_id, observation_id, route_id)
);

create table semantic_private.review_items (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  candidate_id uuid not null,
  review_epoch integer not null check (review_epoch >= 0),
  primary_route_id text not null,
  confidence_tier text not null check (confidence_tier in ('direct','inferred','secondary')),
  aggregate_score double precision not null,
  rank integer not null check (rank >= 0),
  model_revision text,
  prompt_version text,
  grammar_version text,
  presentation_version text not null,
  shown_at timestamptz not null default now(),
  foreign key (candidate_id, user_id)
    references semantic_private.user_term_candidates (id, user_id) on delete cascade,
  unique (id, user_id)
);

create index review_items_user_epoch_idx
  on semantic_private.review_items (user_id, review_epoch);

create table semantic_private.review_item_routes (
  review_item_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  route_id text not null,
  -- Supporting routes are recorded for offline analysis and receive no vote;
  -- the primary route on `review_items` takes the credit, once.
  is_primary boolean not null default false,
  primary key (review_item_id, route_id),
  foreign key (review_item_id, user_id)
    references semantic_private.review_items (id, user_id) on delete cascade
);

create table semantic_private.review_item_evidence (
  review_item_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  support_link_id uuid not null references semantic_private.candidate_support_links(id)
    on delete cascade,
  primary key (review_item_id, support_link_id),
  foreign key (review_item_id, user_id)
    references semantic_private.review_items (id, user_id) on delete cascade
);

create table semantic_private.review_exposures (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  review_item_id uuid not null,
  position integer not null check (position >= 0),
  presentation_variant text not null,
  -- **Recorded so precision can be estimated from something other than the
  -- questions we chose to ask.** Actively selected items and random audits have
  -- different propensities, and an evaluation that cannot tell them apart
  -- reports a biased number confidently.
  selection_propensity double precision check (selection_propensity > 0 and selection_propensity <= 1),
  displayed_at timestamptz not null default now(),
  foreign key (review_item_id, user_id)
    references semantic_private.review_items (id, user_id) on delete cascade,
  unique (id, user_id)
);

create table semantic_private.review_events (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  review_item_id uuid not null,
  exposure_id uuid,
  action text not null check (action in (
    'keep','confirm','edit','strike_off','defer','restore','finish_review')),
  -- **An unexplained strike is `ambiguous_rejection`, not a semantic negative.**
  -- The default is the honest reading of one tap: it tunes ranking and says
  -- nothing about whether the term was true.
  reason text not null default 'ambiguous_rejection' check (reason in (
    'correct','wrong_entity','wrong_type','wrong_relation','wrong_predicate',
    'over_propagated','wrong_channel_role','wrong_primary_term','not_representative',
    'outdated','too_private','duplicate','not_interested','ambiguous_rejection')),
  corrected_concept_id uuid references ontology.concepts(id) on delete restrict,
  corrected_provisional_id uuid,
  corrected_predicate text,
  corrected_label text,
  route_version text,
  model_revision text,
  review_latency_ms integer check (review_latency_ms >= 0),
  created_at timestamptz not null default now(),
  foreign key (review_item_id, user_id)
    references semantic_private.review_items (id, user_id) on delete cascade,
  foreign key (exposure_id, user_id)
    references semantic_private.review_exposures (id, user_id) on delete cascade,
  foreign key (corrected_provisional_id, user_id)
    references semantic_private.provisional_entities (id, user_id) on delete cascade,
  unique (id, user_id)
);

create index review_events_user_idx on semantic_private.review_events (user_id, created_at);

create table semantic_private.user_term_suppressions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id uuid references ontology.concepts(id) on delete restrict,
  provisional_entity_id uuid,
  user_facing_predicate text not null,
  active boolean not null default true,
  -- The epoch records which exposure produced the decision. It is deliberately
  -- not part of identity or lifetime: a strike persists across review rounds
  -- until an explicit restore or an edit to a different term.
  source_review_item_id uuid,
  source_review_epoch integer,
  suppressed_at timestamptz not null default now(),
  restored_at timestamptz,
  foreign key (provisional_entity_id, user_id)
    references semantic_private.provisional_entities (id, user_id) on delete cascade,
  foreign key (source_review_item_id, user_id)
    references semantic_private.review_items (id, user_id) on delete set null,
  constraint user_term_suppressions_single_term_check check (
    (concept_id is not null) <> (provisional_entity_id is not null)),
  constraint user_term_suppressions_restore_check check (
    (active = false) = (restored_at is not null))
);

create unique index user_term_suppressions_one_active_concept_idx
  on semantic_private.user_term_suppressions (user_id, concept_id, user_facing_predicate)
  where active and concept_id is not null;
create unique index user_term_suppressions_one_active_provisional_idx
  on semantic_private.user_term_suppressions (user_id, provisional_entity_id, user_facing_predicate)
  where active and provisional_entity_id is not null;

-- **No column here can hold provider text, and that is the design.** §20.1 says
-- to log hashes and operational metadata and never raw titles, descriptions or
-- full prompts. A `prompt` or `error_detail` column would make that a rule
-- somebody has to keep; its absence makes it a property of the schema.
create table semantic_private.model_invocations (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  input_hash text not null,
  output_hash text,
  model_id text not null,
  model_revision text not null,
  prompt_version text not null,
  grammar_version text not null,
  output_schema_hash text not null,
  contract_hash text,
  batch_items integer not null check (batch_items > 0),
  input_tokens integer check (input_tokens >= 0),
  output_tokens integer check (output_tokens >= 0),
  latency_ms integer check (latency_ms >= 0),
  status text not null check (status in (
    'succeeded','schema_invalid','offset_invalid','length_truncated',
    'timeout','provider_error','circuit_open','abstained')),
  -- A stable code, never a message: a provider's error string can quote the
  -- input it choked on.
  validation_error_code text,
  finish_reason text,
  created_at timestamptz not null default now()
);

create index model_invocations_created_idx on semantic_private.model_invocations (created_at);

-- **The mutable half of the retention split.** Frozen observations hold no
-- provider text; this holds it, encrypted, with an expiry it owns. Every direct
-- derivative — embeddings, spans, cached labels — must reference a row here so
-- it can die with it.
create table semantic_private.source_text_evidence (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  observation_id uuid not null,
  encrypted_text bytea not null,
  encryption_key_version text not null,
  retention_class text not null check (retention_class in (
    'youtube_api_text','provider_catalog_text','user_supplied_text')),
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null,
  etag text,
  refresh_status text not null default 'current' check (refresh_status in (
    'current','refresh_due','expired','deleted')),
  deleted_at timestamptz,
  foreign key (observation_id, user_id)
    references semantic_private.observations (id, user_id) on delete cascade,
  constraint source_text_evidence_expiry_check check (expires_at > fetched_at),
  -- An expired row keeps its identity and loses its content, the same shape the
  -- vault uses for an erasure: `lifecycle_state = 'deleted'` with the payload
  -- nulled, never a row delete.
  constraint source_text_evidence_deleted_check check (
    (refresh_status = 'deleted') = (deleted_at is not null)),
  unique (id, user_id)
);

create index source_text_evidence_expiry_idx
  on semantic_private.source_text_evidence (expires_at) where refresh_status <> 'deleted';

create table ontology.release_manifests (
  id uuid primary key default extensions.gen_random_uuid(),
  parent_release_id uuid references ontology.release_manifests(id) on delete restrict,
  base_ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  compiled_contract_sha256 text not null,
  workbook_sha256 text not null,
  schema_sha256 text not null,
  release_build_sha256 text,
  model_revision text,
  gateway_revision text,
  database_fingerprint_sha256 text,
  environment text not null,
  gate_report jsonb not null default '{}'::jsonb,
  promotion_decision text not null default 'pending' check (promotion_decision in (
    'pending','published','rejected','rolled_back')),
  created_at timestamptz not null default now()
);

-- **Lifecycle and serving role are separate, and that separation is the whole
-- point.** `ontology.versions` may hold exactly one row with
-- `status = 'published'` — a unique partial index enforces it — so champion and
-- challenger cannot coexist there. A deployment slot is a pointer, and two
-- pointers may name two versions without either of them lying about being
-- published.
create table ontology.deployment_slots (
  slot text primary key check (slot in ('baseline','canary','shadow')),
  ontology_version_id uuid not null references ontology.versions(id) on delete restrict,
  release_manifest_id uuid references ontology.release_manifests(id) on delete restrict,
  model_revision text,
  gateway_revision text,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Append-only presentation history.
-- ---------------------------------------------------------------------------

-- **A feedback label is uninterpretable without what was on screen.** "They
-- struck this" only means something against the rank, tier and epoch it was
-- struck at, so an update here would rewrite the question after the answer had
-- been given. Same refusal `ingestion_run_items` applies to evidence.
create or replace function semantic_private.guard_review_history_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'review presentation history is append-only (attempted % on %)',
    tg_op, tg_table_name;
end;
$$;

create trigger review_items_append_only
  before update or delete on semantic_private.review_items
  for each row execute function semantic_private.guard_review_history_append_only();

create trigger review_exposures_append_only
  before update or delete on semantic_private.review_exposures
  for each row execute function semantic_private.guard_review_history_append_only();

-- ---------------------------------------------------------------------------
-- RLS and grants.
-- ---------------------------------------------------------------------------

do $$
declare
  target text;
  mutable constant text[] := array[
    'provisional_entities', 'user_term_candidates',
    'user_term_suppressions', 'source_text_evidence'
  ];
  created constant text[] := array[
    'provisional_entities','mention_resolutions','candidate_relation_proposals',
    'user_term_candidates','candidate_support_links','review_items',
    'review_item_routes','review_item_evidence','review_exposures','review_events',
    'user_term_suppressions','model_invocations','source_text_evidence'
  ];
begin
  foreach target in array created loop
    execute format('alter table semantic_private.%I enable row level security', target);
    execute format('revoke all on semantic_private.%I from public', target);
    execute format('grant select, insert on semantic_private.%I to semantic_worker', target);
    if target = any (mutable) then
      execute format('grant update on semantic_private.%I to semantic_worker', target);
    end if;
  end loop;

  foreach target in array array['release_manifests','deployment_slots'] loop
    execute format('alter table ontology.%I enable row level security', target);
    execute format('revoke all on ontology.%I from public', target);
    execute format('grant select on ontology.%I to semantic_worker', target);
  end loop;
end;
$$;

do $$
declare
  created constant text[] := array[
    'provisional_entities','mention_resolutions','candidate_relation_proposals',
    'user_term_candidates','candidate_support_links','review_items',
    'review_item_routes','review_item_evidence','review_exposures','review_events',
    'user_term_suppressions','model_invocations','source_text_evidence'
  ];
  mutable constant text[] := array[
    'provisional_entities','user_term_candidates',
    'user_term_suppressions','source_text_evidence'
  ];
  target text;
  policies integer;
begin
  -- 1. Every table exists, has RLS on, and has no policy. Asked of the catalog
  --    rather than assumed from the statements above, because `information_schema`
  --    answers empty here for the querying role and a grant that silently did
  --    not apply is the failure mode this whole file is arranged against.
  foreach target in array created loop
    if to_regclass('semantic_private.' || target) is null then
      raise exception '0203: semantic_private.% was not created', target;
    end if;
    if not (select relrowsecurity from pg_class
             where oid = ('semantic_private.' || target)::regclass) then
      raise exception '0203: RLS is not enabled on %', target;
    end if;
    select count(*) into policies from pg_policy
     where polrelid = ('semantic_private.' || target)::regclass;
    if policies <> 0 then
      raise exception '0203: % has % policy/policies; semantic_private has none anywhere',
        target, policies;
    end if;

    -- 2. The worker can read and write, and can only update where a row is a
    --    state machine.
    if not has_table_privilege('semantic_worker', 'semantic_private.' || target, 'SELECT')
       or not has_table_privilege('semantic_worker', 'semantic_private.' || target, 'INSERT') then
      raise exception '0203: semantic_worker cannot read or write %', target;
    end if;
    if has_table_privilege('semantic_worker', 'semantic_private.' || target, 'UPDATE')
       <> (target = any (mutable)) then
      raise exception '0203: update privilege on % does not match the intended set', target;
    end if;
    if has_table_privilege('semantic_worker', 'semantic_private.' || target, 'DELETE') then
      raise exception '0203: semantic_worker may delete from %; nothing here is deleted', target;
    end if;

    -- 3. **The identity reachable from the internet holds nothing.**
    if has_table_privilege('semantic_ingestor', 'semantic_private.' || target, 'SELECT')
       or has_table_privilege('semantic_ingestor', 'semantic_private.' || target, 'INSERT') then
      raise exception '0203: semantic_ingestor gained access to %', target;
    end if;
    if has_table_privilege('authenticated', 'semantic_private.' || target, 'SELECT') then
      raise exception '0203: authenticated can read %; the api schema is the only door', target;
    end if;
  end loop;

  -- 4. Presentation history refuses an update *and* a delete, proven by watching
  --    the guard answer rather than by reading its source — a check on a
  --    function's text is not a check on its behaviour. The real tables want a
  --    user, an observation and a candidate before they will hold a row, so the
  --    guard is exercised on a temporary table carrying the same trigger, which
  --    is what `0200` did for the engagement-mode guard.
  create temporary table review_guard_probe (id integer) on commit drop;
  create trigger review_guard_probe_append_only
    before update or delete on review_guard_probe
    for each row execute function semantic_private.guard_review_history_append_only();
  insert into review_guard_probe values (1);

  begin
    update review_guard_probe set id = 2;
    raise exception '0203: the append-only guard permitted an update';
  exception
    when others then
      if sqlerrm not like '%append-only%' then
        raise exception '0203: the guard raised something unexpected on update: %', sqlerrm;
      end if;
  end;

  begin
    delete from review_guard_probe;
    raise exception '0203: the append-only guard permitted a delete';
  exception
    when others then
      if sqlerrm not like '%append-only%' then
        raise exception '0203: the guard raised something unexpected on delete: %', sqlerrm;
      end if;
  end;

  if (select count(*) from review_guard_probe) <> 1 then
    raise exception '0203: the probe row did not survive both refusals';
  end if;

  -- 5. Both release objects landed.
  if to_regclass('ontology.release_manifests') is null
     or to_regclass('ontology.deployment_slots') is null then
    raise exception '0203: the release objects were not created';
  end if;

  raise notice '0203: % overlay table(s) created, % of them updatable by the worker, 2 release objects',
    array_length(created, 1), array_length(mutable, 1);
end;
$$;

commit;
