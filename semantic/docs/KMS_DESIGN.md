# Envelope encryption for the raw vault — AWS KMS

**Status: provider selected, design drafted, nothing built.** This is the
document §12 of `WRITTEN_REPOSITORY_INTEGRATION.md` asks for — *"before Phase 1,
select and document an envelope-encryption design"* — and it is a prerequisite
of Phase 1 rather than a detail of it.

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

There is no key registry in the schema today, so Phase 1 needs one — a small
migration, and the next free number (currently `0050`, which shifts server
projections and cutover up by one again):

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

**Ingestion: one open sub-decision.** The natural home is a Supabase edge
function, because it can verify the caller's Supabase JWT trivially. But a Deno
function on Supabase needs a long-lived AWS access key in its environment to
call KMS. That does not violate §12 — the *KEK* is still only in AWS, and the
credential grants encrypt-only — but it is a standing secret, which is the
category this project has already lost four keys from.

The alternative is API Gateway + Lambda for ingestion too: no stored credential,
IAM all the way, at the cost of verifying Supabase JWTs ourselves against the
project's JWKS, which is ordinary work rather than novel. **Recommendation: put
ingestion on AWS as well**, so no AWS credential exists outside AWS. Decide
before Phase 1 builds the endpoint, because it determines where the endpoint
lives.

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

1. Settle the ingestion-hosting sub-decision above.
2. Create the two KMS keys and the two IAM roles.
3. Write the key-registry migration.
4. Then Phase 1's envelope and ingestion endpoint, which this unblocks.
