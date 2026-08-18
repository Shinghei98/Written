-- 0235 — a release says which lane it attests, and a gate report is an event.
--
-- Stage 2 of the finalized sequence, first half. `model_invocations` is empty
-- and `release_manifests` has never held a row, so everything here is written
-- before there is anything to migrate — which is the only comfortable time to
-- decide what a release must state.
--
-- ## The gate that could not pass, and reported success anyway
--
-- `0230`'s four-mode commit added `model_lane_mode` to the runtime attestation
-- and taught `evaluate_release` to compare the deployed mode against the
-- manifest's. Its commit message says the test fails today because no manifest
-- carries the field, which is true and is not the whole of it: **the column does
-- not exist and the query does not select it**, so `manifest.get("model_lane_mode")`
-- is `None` for every row that could ever be written. The test is not red
-- pending data. It is red by construction, permanently.
--
-- And the job reported `status: succeeded` with `changed: true` while that test
-- read `failed`, because `changed` was the contract-hash comparison alone. A
-- receipt that says a release was evaluated and changed, standing over a report
-- whose second test could never pass, is worse than a red gate: it is a green
-- one covering a red.
--
-- This adds the column. The Python half — selecting every field it compares and
-- reporting the whole verdict rather than one test's — lands in the same commit.
--
-- ## What a release must state
--
-- The manifest already carried the contract, workbook, schema, build, model
-- revision, gateway revision, database fingerprint and environment. What it
-- could not say is **which lane those identities were attested for**, and what
-- was actually loaded when they were.
--
-- The rule in the check constraint is the one that matters: **a manifest
-- attesting a lane that may call a model must name what it calls.** An `off`
-- manifest legitimately has no gateway image and no tokenizer manifest — there
-- is nothing deployed to name. An `evaluation`, `shadow` or `active` manifest
-- that omits them is claiming a model ran without saying which one, which is the
-- shape of an attestation that attests nothing.
--
-- **The image digests belong here rather than in the image.** A build cannot
-- hash a contract that contains the hash of the same build; the manifest sits
-- outside both and names them, which is the layering `0231`'s memo asked for and
-- the reason `tokenizer_manifest_sha256` on its own was the wrong home for
-- everything.
--
-- ## A gate report is an event
--
-- `gate_report` is one `jsonb` column and `evaluate_release` overwrote it with a
-- blind `set`. Every re-run destroyed the previous verdict, so the question
-- *"did this release ever pass, and when did it stop"* had no answer — and the
-- one grant the worker holds on this table, `update (gate_report)`, is exactly
-- the privilege to destroy it.
--
-- `release_gate_reports` is append-only by trigger, the same refusal
-- `review_items` and `ingestion_run_items` apply to evidence, and for the same
-- reason: a verdict is uninterpretable without when it was reached and what it
-- was reached against. The column stays, unwritten and commented, because
-- dropping it would rewrite a table another migration may reference; the grant
-- that let anything write it does not.

-- ---------------------------------------------------------------------------
-- 1. Which lane, and what was loaded.
-- ---------------------------------------------------------------------------

alter table ontology.release_manifests
  add column if not exists model_lane_mode text,
  -- The manifest already named the model's *revision* and not the model.
  -- Every other field the runtime attestation declares has a column here,
  -- and `evaluate_release` builds its query from those keys — so a field
  -- with no column is a field nothing compares.
  add column if not exists model_id text,
  add column if not exists rollout_scope_revision text,
  add column if not exists tokenizer_runtime_manifest_sha256 text,
  add column if not exists extraction_contract_manifest_sha256 text,
  add column if not exists request_schema_sha256 text,
  add column if not exists prompt_version text,
  add column if not exists grammar_version text,
  add column if not exists gateway_image_digest text,
  add column if not exists serving_image_digest text,
  add column if not exists worker_build_sha256 text;

-- The table has never held a row, so this is a decision rather than a migration:
-- a manifest that does not say which lane it attests is not a manifest.
update ontology.release_manifests set model_lane_mode = 'off'
 where model_lane_mode is null;

alter table ontology.release_manifests
  alter column model_lane_mode set not null;

alter table ontology.release_manifests
  drop constraint if exists release_manifests_model_lane_mode_check;
alter table ontology.release_manifests
  add constraint release_manifests_model_lane_mode_check
  check (model_lane_mode in ('off', 'evaluation', 'shadow', 'active'));

-- **A lane that may call a model must name what it calls.**
alter table ontology.release_manifests
  drop constraint if exists release_manifests_calling_lane_is_named_check;
alter table ontology.release_manifests
  add constraint release_manifests_calling_lane_is_named_check
  check (
    model_lane_mode = 'off'
    or (tokenizer_runtime_manifest_sha256 is not null
        and extraction_contract_manifest_sha256 is not null
        and gateway_image_digest is not null
        and serving_image_digest is not null
        and prompt_version is not null
        and grammar_version is not null));

comment on column ontology.release_manifests.model_lane_mode is
  'The lane these identities were attested for. A manifest recording a model and '
  'a gateway but not the lane it ran in cannot afterwards answer whether the run '
  'was permitted to write anything about a person.';
comment on column ontology.release_manifests.schema_sha256 is
  'The output (response) schema. `request_schema_sha256` is its counterpart and '
  'is null until a request schema exists.';
comment on column ontology.release_manifests.gate_report is
  'Superseded by ontology.release_gate_reports, which is append-only. Left in '
  'place rather than dropped; nothing writes it and no role may.';

-- ---------------------------------------------------------------------------
-- 2. A verdict is an event, not a column.
-- ---------------------------------------------------------------------------

create table if not exists ontology.release_gate_reports (
  id uuid primary key default extensions.gen_random_uuid(),
  -- **`restrict`, not `cascade`.** A cascade would let a verdict be erased by
  -- deleting the release it judged — and the append-only trigger refuses the
  -- cascaded delete anyway, so the pair would simply make a manifest
  -- undeletable with a confusing error. This says the rule directly: a release
  -- carrying verdicts is history and cannot be removed. It is not the `0204`
  -- case, where a `before delete` guard had to permit the erasure a person is
  -- owed; nothing here is user data and no account deletion touches it.
  release_manifest_id uuid not null
    references ontology.release_manifests(id) on delete restrict,
  -- Which evaluator reached the verdict, so two reports on one manifest are
  -- comparable rather than merely consecutive.
  evaluation_revision text not null,
  environment text not null,
  report jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists release_gate_reports_manifest_idx
  on ontology.release_gate_reports (release_manifest_id, created_at desc);

alter table ontology.release_gate_reports enable row level security;
revoke all on ontology.release_gate_reports from public;
grant select, insert on ontology.release_gate_reports to semantic_worker;

create or replace function ontology.guard_gate_report_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'release gate reports are append-only (attempted %)', tg_op;
end;
$$;

drop trigger if exists guard_gate_report_append_only on ontology.release_gate_reports;
create trigger guard_gate_report_append_only
  before update or delete on ontology.release_gate_reports
  for each row execute function ontology.guard_gate_report_append_only();

-- **The privilege that let a verdict be destroyed.** `0208` granted
-- `update (gate_report)` so `evaluate_release` could overwrite it; the append-only
-- table replaces that, and leaving the grant would leave the capability.
revoke update (gate_report) on ontology.release_manifests from semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  -- The column the gate compares. Its absence is why the test could never pass,
  -- and reading it back from the catalog is the check that would have caught it.
  select count(*) into n
    from information_schema.columns
   where table_schema = 'ontology' and table_name = 'release_manifests'
     and column_name = 'model_lane_mode' and is_nullable = 'NO';
  if n <> 1 then
    raise exception '0235: release_manifests.model_lane_mode is missing or nullable';
  end if;

  -- An attestation for a calling lane that names nothing must be refused. Stated
  -- as a transformation rather than a count, so it answers on an empty database.
  begin
    insert into ontology.release_manifests
      (base_ontology_version_id, compiled_contract_sha256, workbook_sha256,
       schema_sha256, release_build_sha256, database_fingerprint_sha256,
       environment, promotion_decision, model_lane_mode)
    select v.id, repeat('0', 64), repeat('0', 64), repeat('0', 64),
           repeat('0', 64), repeat('0', 64), 'contract_probe', 'pending',
           'evaluation'
      from ontology.versions v where v.status = 'published' limit 1;
    raise exception '0235: an evaluation manifest naming no gateway was accepted';
  exception
    when check_violation then null;
  end;

  -- And the worker may no longer overwrite a verdict.
  if has_column_privilege('semantic_worker', 'ontology.release_manifests',
                          'gate_report', 'UPDATE') then
    raise exception '0235: semantic_worker can still overwrite gate_report';
  end if;

  if not has_table_privilege('semantic_worker', 'ontology.release_gate_reports',
                             'INSERT') then
    raise exception '0235: semantic_worker cannot append a gate report';
  end if;
end;
$$;
