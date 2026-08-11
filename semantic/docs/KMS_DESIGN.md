# Envelope encryption for the raw vault — AWS KMS

**Status: keys and roles exist; nothing uses them yet.** This is the document
§12 of `WRITTEN_REPOSITORY_INTEGRATION.md` asks for — *"before Phase 1, select
and document an envelope-encryption design"* — and it is a prerequisite of
Phase 1 rather than a detail of it.

## What exists, as of 2026-08-10

Account `616040526027`, region `us-east-1` (matching the Supabase project, so
the Lambda↔Postgres hop stays in-region).

| | |
|---|---|
| `alias/written-raw-vault` | `arn:aws:kms:us-east-1:616040526027:key/206aa3c6-4674-4dac-a02a-22d95fb64e81` — symmetric, **automatic rotation on** |
| `alias/written-lineage-hmac` | `arn:aws:kms:us-east-1:616040526027:key/74a0c1a1-51c9-492d-bd60-e81ec4457e02` — `HMAC_256`, `GENERATE_VERIFY_MAC`. **HMAC keys cannot auto-rotate**; rotation here is manual and versioned. |
| `written-semantic-ingestion` | Lambda role. `GenerateDataKey`, `Encrypt`, `GenerateMac`. **No `Decrypt`.** |
| `written-semantic-worker` | Lambda role. `Decrypt`, `GenerateMac`, `VerifyMac`. **No `GenerateDataKey`.** |

Both roles carry `AWSLambdaBasicExecutionRole` for logging and nothing else.
Neither can `ScheduleKeyDeletion` — destroying a key is an outage, not an
operation either of these should be able to reach.

**Verified by simulation, not by reading the JSON**, and that mattered:

```
ingestion  GenerateDataKey  allowed        worker  Decrypt          allowed
ingestion  Encrypt          allowed        worker  GenerateDataKey  implicitDeny
ingestion  Decrypt          implicitDeny   worker  GenerateMac      allowed
```

### The trap that cost a round, worth writing down

The first version of both policies used a bare `StringEquals` on
`kms:EncryptionContextKeys`. Every vault action came back `implicitDeny` and the
policy JSON looked perfectly correct.

**`kms:EncryptionContextKeys` is multivalued, and a bare operator never matches
one.** It needs a set operator, and which one is not cosmetic:
`ForAllValues:StringEquals` is vacuously true for an *empty* context — so it
would permit exactly the call we are trying to forbid — while
`ForAnyValue:StringEquals` requires `user_id` to actually be present. It is
`ForAnyValue`.

Had this shipped it would have denied everything in production, which is the
lucky failure. The unlucky version is the `ForAllValues` one, which fails open.

The scheme names no vendor. `DECISIONS.md` files *"the selected KMS/HSM
provider, envelope-key hierarchy, worker-hosting environment, decrypt audit
sink, rotation schedule, and backup-erasure procedure"* under **"Not implemented
or intentionally deferred"**. AWS is our choice, not the scheme's.

---

## What is being protected, and from whom

Whole Calendar events and HealthKit records — real titles, "Outpatient", a
therapist's name — kept so they can be reclassified later as the ontology
improves. The threat model is **anyone holding the database**: Supabase staff, a
leaked connection string, a backup, us. Supabase already encrypts the disk;
that stops a stolen drive and nothing else.

Worth stating plainly: **today none of this is encrypted.** Production holds
1,811 calendar rows with titles and organisers in plain columns via the legacy
path. This design does not make that worse — it is what makes the *new* path
better, and the legacy rows are a separate migration problem.

## The shape

Standard envelope encryption, which is what `raw_source_records`' existing
`encryption_key_version text not null` and `encrypted_payload bytea` already
assume:

1. One symmetric **KMS key** (the KEK). It never leaves AWS.
2. Per user, one **data key** (DEK), produced by `GenerateDataKey`. AWS returns
   the plaintext key and a wrapped copy; we use the plaintext, then discard it,
   and store only the wrapped copy.
3. Payloads are encrypted with the DEK — AES-GCM — and the ciphertext goes in
   `encrypted_payload`.
4. To read, the worker calls `Decrypt` on the wrapped DEK, uses it, discards it.

**Encryption context is not optional.** Every `GenerateDataKey` and `Decrypt`
passes `{"user_id": "<uuid>"}` as the encryption context, which AWS binds into
the wrapped key. A wrapped DEK stolen from user A's row cannot be unwrapped
while claiming to be user B — the call simply fails. Without it, one leaked blob
plus decrypt permission reads anybody.

### Where the wrapped key lives

`0050_semantic_user_encryption_keys.sql` — **applied to production
2026-08-10**, and applied-then-replayed by `tools/replay_contracts.sh` on every
run. Taking `0050` shifts server projections to `0051` and cutover to `0052`.

```
semantic_private.user_encryption_keys
  user_id      uuid   references auth.users(id) on delete cascade
  key_version  text   -- what `raw_source_records.encryption_key_version` records
  wrapped_dek  bytea  -- the KMS CiphertextBlob; useless without KMS
  created_at   timestamptz
  retired_at   timestamptz   -- set on rotation; rows keep decrypting by version
  primary key (user_id, key_version)
```

RLS on, no policy, `service_role` only — the posture every other
`semantic_private` table already has. The wrapped blob is safe at rest by
construction: it is unusable without a `kms:Decrypt` call that AWS logs.

Behaviour verified against a real chain rather than read off the DDL: a second
*active* key for one user is refused by the partial unique index; retiring the
first then admitting a second works, which is rotation; a malformed ARN is
refused; and **deleting the account cascades the keys to zero** — crypto-erasure
with nothing to remember to call.

## §12's six requirements, answered

| Requirement | How |
|---|---|
| KEK never in the binary, a Postgres row, a worker env file, or the repo | The KEK is a KMS key ID. It is an *identifier*, not key material — the key itself cannot be exported from AWS by anyone, including us. |
| Per-user DEKs, wrapped, with a recorded key version, rotation not changing semantic identity | `user_encryption_keys` above. Rotation writes a new `key_version`; old rows keep their own and stay readable. Nothing about a row's identity — `source_item_hmac`, `record_fingerprint` — is derived from the DEK, so rotation cannot disturb it. |
| A **separate** secret for lineage HMACs | A second KMS key, `written/lineage-hmac`, used with `GenerateMac` — never the payload key. This is what stops a database reader who somehow obtains the payload key from also being able to test guesses against `source_item_hmac` and `content_lineage_hmac`, which are computed over predictable inputs. |
| Decrypt limited to the worker path, audited, no plaintext in logs/queues/errors | Two IAM roles, and the split is the point: the **ingestion** identity gets `GenerateDataKey` + `Encrypt` and **not** `Decrypt`; the **worker** identity gets `Decrypt`. So the thing exposed to the internet can write into the vault and cannot read it back. CloudTrail records every call with identity, encryption context and time — that is the audit sink §12 wants, and we do not have to build it. |
| Deletion across ciphertext, object storage, dead-letter artifacts, backups | **Crypto-erasure: delete the user's `user_encryption_keys` row.** Every payload of theirs becomes permanently unreadable, including in backups we cannot reach into and in any dead-letter copy. Account deletion already cascades from `auth.users`, so this happens for free — which is the single biggest reason to do it this way. |
| Tested crypto-erasure and rotation recovery | An acceptance test: encrypt, delete the key row, confirm decrypt fails; and rotate, confirm old-version rows still read. |

**The trap worth writing down:** crypto-erasure means deleting the *wrapped DEK
row*, never the KMS key. Deleting the KMS key erases every user at once and is
irreversible after the waiting period. One is a routine deletion request; the
other is an outage.

Note also what AWS's automatic annual rotation does and does not do: it rotates
the KEK's backing material and retains the old, so existing wrapped DEKs keep
unwrapping. It does **not** re-wrap them. Per-user DEK rotation is our job and
is the `key_version` column's reason for existing.

## Where things run

Choosing AWS for the key forces the hosting question the scheme bundles into the
same bullet — you cannot scope "only the worker may decrypt" to a worker with no
identity.

**Worker: AWS Lambda on an EventBridge schedule.** It fits what the worker
already is — `SemanticWorker.run_once()` claims one job and returns, and the CLI
*requires* `--once`; there is no loop anywhere in the package. A Lambda gets an
IAM role natively, so `Decrypt` is scoped to it with no credential stored
anywhere. This also closes Gate 2, which had no answer at all: the project's
only compute is three Deno edge functions and a static Cloudflare site.

**Ingestion: on AWS too — decided.** API Gateway + Lambda, not a Supabase edge
function. The edge function was tempting because it can verify the caller's
Supabase JWT trivially, but a Deno function on Supabase would need a long-lived
AWS access key in its environment to reach KMS. That does not violate §12 — the
KEK is still only in AWS and the credential would be encrypt-only — but it is a
standing secret, and this project has lost four keys, every one a standing
secret somewhere it did not need to be. On AWS there is no credential at all:
the Lambda assumes `written-semantic-ingestion` and that is the whole story.

The cost is verifying Supabase tokens ourselves, and it is smaller than it
sounds. The project publishes a JWKS — confirmed live, one EC key, `ES256`,
`use: sig` — at
`https://fwnezkbesjoazlpaflbq.supabase.co/auth/v1/.well-known/jwks.json`, so any
standard JOSE library verifies an access token against a public key with **no
shared secret**. The user id is the token's `sub`, which is what the endpoint
needs and what §4 means by "derives the user from the access token".

## Cost

About **$1/month per KMS key** — two keys, so ~$2 — plus $0.03 per 10,000
requests. Lambda at this volume is inside the free tier. The real cost is setup
and a third cloud vendor alongside Supabase and Cloudflare, not the bill.

## What this unlocks, concretely

- **Deletion requests** become one row deletion instead of chasing ciphertext
  through backups nobody can reach.
- **Apple review** gets a defensible answer about HealthKit storage, which
  matters because HealthKit is reviewed on purpose limitation.
- **The training corpus** in `private.collaborators` only becomes arguable once
  raw capture is encrypted and scoped.

## Not decided here

Rotation cadence; the CloudTrail retention window and whether it needs its own
alerting; the AWS account and region; whether the retention worker
(`retained_until` is not a TTL — the schema validates it and nothing enforces
it) shares the Lambda or gets its own schedule.

## Next

1. ~~Create the two KMS keys and the two IAM roles.~~ **Done** — see above.
2. **Delete the `written-setup` access key.** It is AdministratorAccess on a
   laptop, and nothing routine needs it now: both Lambdas use their roles.
   IAM → Users → `written-setup` → Security credentials → deactivate, then
   delete. Recreate for an afternoon if more setup is ever needed.
3. ~~Settle the ingestion-hosting sub-decision.~~ **Done — AWS.**
4. ~~The key-registry migration.~~ **Done — `0050`, passing, not yet applied to
   production.**
5. ~~Apply `0050` to production.~~ **Done** — RLS on with no policy, zero rows,
   `private` ACL fingerprint identical either side. See `supabase/DEPLOY.md`.
6. **Phase 1**, which nothing now blocks: the typed `SourceEnvelope` /
   `SourcePayload` in Swift, and the API Gateway + Lambda ingestion endpoint.
   The first thing it must do is `GenerateDataKey` and write the row `0050`
   defines — until something does, the vault has a lock and no key.
