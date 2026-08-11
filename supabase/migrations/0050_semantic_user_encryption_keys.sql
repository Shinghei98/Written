-- 0050 — where a user's wrapped data key lives.
--
-- `raw_source_records` has carried `encryption_key_version text not null` and
-- `encrypted_payload bytea` since `0046`, which is the envelope pattern assumed
-- but never completed: there was nowhere to put the wrapped key that the
-- version names. This is that place, and it is the last piece of schema Phase 1
-- needs before an ingestion endpoint can write ciphertext.
--
-- The design it implements is `semantic/docs/KMS_DESIGN.md`. In short: AWS KMS
-- holds one symmetric key that never leaves it; each user gets a data key from
-- `GenerateDataKey`; we use the plaintext copy, discard it, and store only the
-- wrapped copy here. Reading means asking KMS to unwrap, and only the worker's
-- IAM role may.
--
-- **This is what makes deletion honest.** Crypto-erasure: drop a user's row and
-- every payload of theirs becomes permanently unreadable — including in backups
-- nobody can reach into, and in any dead-letter copy. The cascade from
-- `auth.users` means account deletion already does it, which is most of why the
-- envelope is worth the trouble at all.
--
-- **The trap, stated once here and once in the design:** erasure deletes a row
-- in this table, *never* the KMS key. Deleting the KMS key erases every user at
-- once and is irreversible after its waiting period. One is a routine deletion
-- request; the other is an outage.
--
-- Ships no product behaviour. Nothing writes this table yet.

begin;

create table if not exists semantic_private.user_encryption_keys (
  user_id uuid not null references auth.users(id) on delete cascade,

  -- What `raw_source_records.encryption_key_version` records, so a row written
  -- under an old key still says which one to ask for. Free text rather than a
  -- serial because it has to survive re-keying under a *different* KMS key, and
  -- a number would imply an ordering that does not exist across keys.
  key_version text not null,

  -- The `CiphertextBlob` from `GenerateDataKey`. Safe at rest by construction:
  -- useless without a `kms:Decrypt` call that AWS logs and only one role may
  -- make. Not `not null` by accident — a row here with no blob would be a user
  -- whose data can never be read, which is a bug rather than a state.
  wrapped_dek bytea not null,

  -- Which KMS key wrapped it. Recorded rather than assumed because rotating to
  -- a new *key* — as opposed to AWS's automatic rotation of one key's backing
  -- material, which keeps old blobs unwrapping — means two keys are live at
  -- once, and a blob cannot be unwrapped by the wrong one.
  kms_key_arn text not null,

  created_at timestamptz not null default now(),

  -- Set when a newer version supersedes this one. **Retired is not deleted**:
  -- rows encrypted under it still name it, and dropping it would erase them.
  -- Only an erasure request deletes.
  retired_at timestamptz,

  primary key (user_id, key_version),

  constraint user_encryption_keys_version_v031_check
    check (key_version ~ '^[a-z0-9][a-z0-9_.:-]{0,63}$'),
  constraint user_encryption_keys_arn_v031_check
    check (kms_key_arn ~ '^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/.+$'),
  constraint user_encryption_keys_blob_v031_check
    check (octet_length(wrapped_dek) between 1 and 4096)
);

-- One live key per person. A second would make "which key encrypts the next
-- payload" ambiguous, and the answer would differ between two writers racing.
create unique index if not exists user_encryption_keys_active_v031_idx
  on semantic_private.user_encryption_keys (user_id)
  where retired_at is null;

comment on table semantic_private.user_encryption_keys is
  'Per-user wrapped data keys for the encrypted raw vault. Deleting a row is '
  'crypto-erasure: every payload of that user becomes permanently unreadable, '
  'backups included. Never delete the KMS key itself — that erases everybody.';

-- Explicit, because `0043`'s `grant ... on all tables in schema` bound at
-- execution time and covers nothing added afterwards. Same trap `0048` records.
revoke all on table semantic_private.user_encryption_keys
  from public, anon, authenticated, service_role;
grant select, insert, update, delete
  on table semantic_private.user_encryption_keys to service_role;

alter table semantic_private.user_encryption_keys enable row level security;

-- RLS on, no policy: deny-all to every client role, reachable only by
-- `service_role`, which bypasses it. The posture every other
-- `semantic_private` table has, and the reason there is nothing to write here.

commit;
