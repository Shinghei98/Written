-- 0236 — an invocation item is the unit that can be answered for.
--
-- Stage 2, second half. `model_invocations` records a batch: `batch_items` is a
-- count, `input_hash` and `output_hash` cover the whole call, and `status` is one
-- word for however many items it carried. Nothing in it can say **which
-- observation produced which item**, so every question that matters about a
-- model call has no answer:
--
-- - a retry cannot be told from a second attempt at something else;
-- - an erasure cannot find the derivatives of one person's source row;
-- - a stale source cannot be caught between the read and the commit;
-- - a mode boundary cannot be enforced against a row that names no lane.
--
-- Repo-wide, nothing references `model_invocations` in either direction. It is a
-- table with no lineage attached, which is why this is additive rather than a
-- migration: there is nothing to move.
--
-- ## Every model-created row must point at one successful item
--
-- That is the rule this table exists to make possible, and it is not enforced
-- here — the write guards are the next commit. What lands now is the thing they
-- will point at, because a guard requiring a foreign key to a table that does
-- not exist is not a guard.
--
-- ## The outcome vocabulary is closed, and separate from abstention
--
-- Fourteen operational outcomes, none of which is a semantic abstention.
-- `semantic_abstention` appears among them as the one outcome that *is* the
-- model's own answer — the item had no durable subject — and everything else is
-- something that happened to the call. `mention_extract_v2`'s validator already
-- refuses to let a structural refusal become an abstain reason, and
-- `0236_no_mentions_without_success` is the same rule one layer down: **only a
-- `succeeded` item may carry mentions.** An abstention that reported three
-- mentions, or a timeout that did, would be a bug arriving in somebody's profile
-- as evidence about them.
--
-- ## Two outcome vocabularies now exist, and that is recorded rather than hidden
--
-- `model_invocations.status` has eight values from `0203`; this has fourteen,
-- and they do not line up: `abstained` against `semantic_abstention`,
-- `length_truncated` against `output_overflow`, and nine outcomes the call-level
-- column cannot express at all. That is one fact in two vocabularies, which is
-- this repository's recurring defect and is not resolved here.
--
-- It is left because nothing writes either column yet and the gateway that will
-- write both does not exist: reconciling now would be choosing between two
-- guesses. **The item vocabulary is the authoritative one** — it is the grain a
-- retry, an erasure and a mode boundary are answered at — and Stage 3 either
-- derives the call-level status from its items or drops it. Whichever it does,
-- it should not be able to happen by accident, so this paragraph is here to be
-- found.
--
-- ## Identity is keyed, never a bare digest
--
-- `input_fingerprint` and `output_fingerprint` are keyed HMACs with the key
-- version recorded beside them, for the reason `content_lineage_hmac` is salted
-- per user: an unsalted digest of a song or video title is a **cross-account
-- correlation handle**, because the titles are low-entropy and shared. The same
-- two people liking the same track would produce the same hash in both accounts,
-- and a column meant to detect a duplicate call would answer a question nobody
-- was allowed to ask. The key lives outside the database; only its version is
-- recorded, and the pattern is checked so a version that cannot be resolved is
-- refused at the write rather than at the read.
--
-- ## No column here can hold provider text
--
-- Not a prompt, a title, a description, a response body or a provider error
-- message. `0203` said the same about `model_invocations` and the discipline is
-- the same: an `error_detail` column would make §20.1 a rule somebody has to
-- remember. The columns are counts, identifiers, digests and closed vocabularies,
-- and `supabase/tests/0236_invocation_lineage_contract.sql` holds the allowlist
-- so that adding one is a decision rather than an omission.
--
-- ## Append-only
--
-- The same refusal `ingestion_run_items` applies to evidence. An item's outcome
-- is known when it is written; a retry is a **new item naming its parent**, not
-- an edit to the old one. Rewriting an outcome after the fact would make the
-- retry ancestry a story about what we currently believe rather than what
-- happened.

-- ---------------------------------------------------------------------------
-- 1. The call names its release and its lane.
-- ---------------------------------------------------------------------------

alter table semantic_private.model_invocations
  add column if not exists release_manifest_id uuid
    references ontology.release_manifests(id) on delete restrict,
  add column if not exists model_lane_mode text,
  add column if not exists gateway_image_digest text;

alter table semantic_private.model_invocations
  drop constraint if exists model_invocations_lane_mode_check;
alter table semantic_private.model_invocations
  add constraint model_invocations_lane_mode_check
  check (model_lane_mode is null
         or model_lane_mode in ('off', 'evaluation', 'shadow', 'active'));

comment on column semantic_private.model_invocations.release_manifest_id is
  'Which attested release this call ran under. Nullable only because the table '
  'predates the manifest; every call written from here on names one.';

-- ---------------------------------------------------------------------------
-- 2. The item.
-- ---------------------------------------------------------------------------

create table if not exists semantic_private.model_invocation_items (
  id uuid primary key default extensions.gen_random_uuid(),
  invocation_id uuid not null,
  item_index integer not null check (item_index >= 0),

  -- **Null for a fixture.** An evaluation run over synthetic items belongs to
  -- nobody, and forcing a user id would either invent one or push fixtures out
  -- of this table and out of the lineage.
  user_id uuid references auth.users(id) on delete cascade,
  observation_id uuid,
  source_text_evidence_id uuid,
  source_revision text,

  -- **What makes a retry the same work.** Over the source revision, model,
  -- prompt, grammar, request and output schemas, contract and route — so a
  -- second attempt at one item is recognisable as such, and a re-run after any
  -- of those moved is correctly a different extraction rather than a duplicate.
  logical_extraction_key text not null check (length(btrim(logical_extraction_key)) > 0),

  attempt integer not null default 1 check (attempt >= 1),
  -- A retry names the item it retries. Ancestry rather than a counter, because
  -- a counter cannot say which attempt produced the row that survived.
  parent_item_id uuid references semantic_private.model_invocation_items(id)
    on delete no action,

  outcome text not null check (outcome in (
    'succeeded',
    'semantic_abstention',
    'input_oversize',
    'output_overflow',
    'schema_invalid',
    'offset_invalid',
    'missing_item',
    'duplicate_item',
    'source_stale',
    'timeout',
    'rate_limited',
    'provider_error',
    'contract_mismatch',
    'circuit_open')),
  mention_count integer not null default 0 check (mention_count >= 0),

  estimated_output_tokens integer check (estimated_output_tokens >= 0),
  -- Only a singleton call can attribute output tokens to an item; in a pair the
  -- server counts the response, not the halves.
  actual_output_tokens integer check (actual_output_tokens >= 0),

  input_fingerprint bytea,
  output_fingerprint bytea,
  fingerprint_key_version text,

  created_at timestamptz not null default now(),

  -- Tenancy the way `0203` does it: a child proves it belongs to the same
  -- account as its parent rather than a query being careful.
  unique (id, user_id),
  unique (invocation_id, item_index),

  constraint model_invocation_items_invocation_fk
    foreign key (invocation_id)
    references semantic_private.model_invocations(id) on delete no action,

  -- An item about somebody's observation is an item about somebody.
  constraint model_invocation_items_user_scope_check
    check (observation_id is null or user_id is not null),

  -- **Only a succeeded item may carry mentions.** The storage-layer half of the
  -- rule the validator already enforces on the wire: a structural failure is not
  -- evidence about a person, and neither is an abstention.
  constraint model_invocation_items_no_mentions_without_success
    check (outcome = 'succeeded' or mention_count = 0),

  -- A keyed fingerprint names its key, or it cannot be resolved later and is a
  -- bare digest of a low-entropy title after all.
  constraint model_invocation_items_fingerprint_key_check
    check ((input_fingerprint is null and output_fingerprint is null)
           = (fingerprint_key_version is null)),
  constraint model_invocation_items_fingerprint_key_pattern_check
    check (fingerprint_key_version is null
           or fingerprint_key_version ~ '^[A-Za-z0-9_.:-]{3,64}$'),

  -- A retry is a later attempt, always.
  constraint model_invocation_items_retry_attempt_check
    check (parent_item_id is null or attempt > 1)
);

create index if not exists model_invocation_items_invocation_idx
  on semantic_private.model_invocation_items (invocation_id, item_index);
create index if not exists model_invocation_items_user_idx
  on semantic_private.model_invocation_items (user_id)
  where user_id is not null;
create index if not exists model_invocation_items_observation_idx
  on semantic_private.model_invocation_items (observation_id)
  where observation_id is not null;
-- **One standing success per logical extraction.** A retry that succeeds twice
-- for the same work is a duplicate, and this is where that is refused rather
-- than counted.
create unique index if not exists model_invocation_items_one_success_idx
  on semantic_private.model_invocation_items (logical_extraction_key)
  where outcome = 'succeeded';

comment on table semantic_private.model_invocation_items is
  'One row per item of one model call. Every model-created mention must point at '
  'a successful row here. No column may hold provider text: not a prompt, a '
  'title, a description, a response body or a provider error message.';

-- ---------------------------------------------------------------------------
-- 3. Append-only.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.guard_invocation_item_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The `0204` shape: refuse while the owner exists, permit once they are gone,
  -- so an account deletion cascading through `user_id` is not blocked by the
  -- guard that protects the evidence.
  if tg_op = 'DELETE'
     and old.user_id is not null
     and not exists (select 1 from auth.users u where u.id = old.user_id) then
    return old;
  end if;
  raise exception 'model invocation items are append-only (attempted %)', tg_op;
end;
$$;

drop trigger if exists guard_invocation_item_append_only
  on semantic_private.model_invocation_items;
create trigger guard_invocation_item_append_only
  before update or delete on semantic_private.model_invocation_items
  for each row execute function semantic_private.guard_invocation_item_append_only();

alter table semantic_private.model_invocation_items enable row level security;
revoke all on semantic_private.model_invocation_items from public;
grant select, insert on semantic_private.model_invocation_items to semantic_worker;

-- ---------------------------------------------------------------------------
-- 4. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  -- `semantic_ingestor` writes vault rows and reads none back. It has no
  -- business here, and `on all tables` binds at execution time so a later
  -- migration's grant is the only way it could acquire one.
  if has_table_privilege('semantic_ingestor',
                         'semantic_private.model_invocation_items', 'SELECT')
     or has_table_privilege('semantic_ingestor',
                            'semantic_private.model_invocation_items', 'INSERT') then
    raise exception '0236: semantic_ingestor can reach invocation items';
  end if;

  if not has_table_privilege('semantic_worker',
                             'semantic_private.model_invocation_items', 'INSERT') then
    raise exception '0236: semantic_worker cannot write an invocation item';
  end if;
  if has_table_privilege('semantic_worker',
                         'semantic_private.model_invocation_items', 'UPDATE') then
    raise exception '0236: semantic_worker can rewrite an invocation item';
  end if;

  -- The fourteen outcomes, read back from the constraint rather than trusted to
  -- the comment above it. A fifteenth added without thought fails here.
  select count(*) into n
    from pg_constraint c
    join pg_class r on r.oid = c.conrelid
    join pg_namespace ns on ns.oid = r.relnamespace
   where ns.nspname = 'semantic_private'
     and r.relname = 'model_invocation_items'
     and c.conname like '%outcome%'
     and pg_get_constraintdef(c.oid) like '%semantic_abstention%'
     and pg_get_constraintdef(c.oid) like '%circuit_open%'
     and pg_get_constraintdef(c.oid) like '%contract_mismatch%';
  if n <> 1 then
    raise exception '0236: the closed outcome vocabulary is not in place';
  end if;
end;
$$;
