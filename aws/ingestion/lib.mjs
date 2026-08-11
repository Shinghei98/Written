// The parts of the ingestion endpoint that are pure functions of their input.
//
// Split out from `index.mjs` for one reason: everything here can be tested
// without AWS, without Postgres and without a network, and everything that
// cannot be is in the handler. The interesting mistakes in this endpoint are
// all in this file — a fingerprint that is not stable, a canonical form that
// depends on key order, a purpose taken from the caller — and none of them
// would be caught by an integration test that only checks a row appeared.

import { createHmac, randomBytes, createCipheriv } from "node:crypto";

// The eleven `semantic_private.sources` rows, and the app-side names that map
// onto them. `health` against `healthkit` is the only translation and it is
// real: every distiller writes the first, the schema uses the second, and
// renaming either rewrites history in a table that is append-only by design.
// This mirrors `SemanticSource.appSourceCode` in Swift.
export const SOURCE_CODES = new Set([
  "apple_music", "music_library", "spotify", "apple_podcasts", "podcast",
  "apple_calendar", "google_calendar", "healthkit", "youtube", "location", "user",
]);

const APP_SOURCE_ALIASES = { health: "healthkit" };

export function normalizeSource(code) {
  const resolved = APP_SOURCE_ALIASES[code] ?? code;
  return SOURCE_CODES.has(resolved) ? resolved : null;
}

// **The purpose is decided here, not by the caller.**
//
// §4 asks the service to validate purpose; deriving it is strictly stronger. A
// client that chooses its own consent purpose can file HealthKit under
// `source_distillation` and walk around the grant the v0.3.1 contract wants
// HealthKit transfer gated on. Whatever the envelope says is discarded.
//
// Mirrors `SemanticSource.dataUsePurpose` in Swift, and the two must agree —
// but if they ever disagree, this one wins, because this one is the one a
// modified client cannot change.
export function consentPurposeFor(sourceCode) {
  switch (sourceCode) {
    case "apple_calendar":
    case "google_calendar":
      return "calendar_distillation";
    case "healthkit":
      return "fitness_connection";
    default:
      return "source_distillation";
  }
}

export const RETENTION_POLICY_VERSION = "written-retention-v1";

// A JSON form that does not depend on key order.
//
// **This is load-bearing rather than tidy.** `record_fingerprint` is computed
// over the payload and drives idempotency through a unique index, so if the
// same content can serialise two ways, a retry writes a second row and the
// vault grows without bound while every count downstream doubles. `JSON.stringify`
// preserves insertion order, and insertion order is whatever the client's
// encoder happened to do that day.
export function canonicalize(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(value[k])}`).join(",")}}`;
}

// Which item this is, opaquely.
//
// **Salted with the user id on purpose.** Without it, two accounts with the
// same song produce the same hash, so anybody holding the database learns who
// shares a library with whom — from a column that exists precisely so the vault
// can tell rows apart without holding anything identifying. Nothing downstream
// needs to compare items across users: concept resolution happens in the worker,
// on decrypted payloads.
export function sourceItemHmac(key, { userId, sourceCode, providerItemId }) {
  return createHmac("sha256", key)
    .update(`written:item:v1\n${userId}\n${sourceCode}\n${providerItemId}`)
    .digest("hex");
}

// Which *version* of the item this is.
//
// Includes the payload, so a changed observation is a new row rather than a
// silent overwrite — the same append-only reading `append_source_records` takes
// on the legacy path, where "we kept it, marked as removed" is the answer that
// fails an audit. Re-sending unchanged content collides and is skipped.
export function recordFingerprint(key, { userId, sourceCode, dataType, providerItemId, occurredAt, payload }) {
  return createHmac("sha256", key)
    .update(
      `written:record:v1\n${userId}\n${sourceCode}\n${dataType}\n` +
        `${providerItemId}\n${occurredAt ?? ""}\n${canonicalize(payload)}`
    )
    .digest("hex");
}

// AES-256-GCM, `iv || ciphertext || tag`.
//
// A fresh 12-byte IV per record, which is not optional: GCM repeats catastrophically
// under a reused (key, IV) pair — an attacker who sees two records encrypted with
// the same pair recovers their XOR and can forge tags. The DEK is per call and
// short-lived, but "short-lived" is not "used once".
export function encryptPayload(dek, plaintextUtf8) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", dek, iv);
  const body = Buffer.concat([cipher.update(plaintextUtf8, "utf8"), cipher.final()]);
  return Buffer.concat([iv, body, cipher.getAuthTag()]).toString("base64");
}

export class InvalidEnvelope extends Error {
  constructor(index, message) {
    super(`records[${index}]: ${message}`);
    this.index = index;
    this.status = 400;
  }
}

// One envelope in, one row for `ingest_source_records_v031` out.
//
// The caller supplies `connectorSource` (whose distillation this is) separately
// from each envelope's `record_source_code` (whose data the row is). They are
// equal most of the time, and `connector_record_source_matrix` refuses any pair
// nobody has declared — which is `0048`'s provenance fix and the reason an
// Apple Music run can carry a `user` row without that row becoming listening
// evidence.
export function toRecordRow(envelope, index, { userId, hmacKey, dek }) {
  const sourceCode = normalizeSource(envelope?.record_source_code);
  if (!sourceCode) throw new InvalidEnvelope(index, `unknown record_source_code`);

  const dataType = envelope.data_type;
  if (typeof dataType !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(dataType)) {
    throw new InvalidEnvelope(index, "data_type must match ^[a-z][a-z0-9_]{0,63}$");
  }

  const providerItemId = envelope.provider_item_id;
  if (typeof providerItemId !== "string" || providerItemId.length === 0) {
    throw new InvalidEnvelope(index, "provider_item_id is required");
  }

  let occurredAt = null;
  if (envelope.source_event_at != null) {
    const parsed = new Date(envelope.source_event_at);
    if (Number.isNaN(parsed.getTime())) throw new InvalidEnvelope(index, "source_event_at is not a date");
    occurredAt = parsed.toISOString();
  }

  // The whole envelope is what gets encrypted, minus the fields that are about
  // storage rather than about the observation. The typed payload alone would
  // lose the action, and the action is the thing the semantic system weighs.
  const { typed_payload: typedPayload, ...rest } = envelope;
  const sealed = { ...rest, typed_payload: typedPayload ?? null };
  delete sealed.consent_purpose; // derived, never the caller's

  return {
    record_source_code: sourceCode,
    data_type: dataType,
    occurred_at: occurredAt,
    source_item_hmac: sourceItemHmac(hmacKey, { userId, sourceCode, providerItemId }),
    record_fingerprint: recordFingerprint(hmacKey, {
      userId, sourceCode, dataType, providerItemId, occurredAt, payload: sealed,
    }),
    encrypted_payload_b64: encryptPayload(dek, canonicalize(sealed)),
    consent_purpose: consentPurposeFor(sourceCode),
    retention_policy_version: RETENTION_POLICY_VERSION,
  };
}

// `^[a-z0-9][a-z0-9_.-]{0,63}$` — `0051` aligned this with
// `raw_source_records.encryption_key_version`, and a version this side refuses
// is far better than one Postgres refuses after the payload is already
// encrypted under it.
export function keyVersionFor(uuid) {
  const version = `dek-${uuid}`;
  if (!/^[a-z0-9][a-z0-9_.-]{0,63}$/.test(version)) {
    throw new Error(`generated key version is not storable: ${version}`);
  }
  return version;
}
