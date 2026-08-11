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

// Which head an observation belongs under.
//
// **A scope is `(source, data_type, action)` because
// `ingestion_run_scopes.action_type` is `not null`** — so a record carrying no
// action belongs to no scope, gets no run item, and is never promoted to
// current state. It is still captured and still encrypted; it simply is not
// evidence. `user/bio`, a calendar container, the Apple Music subscription
// flag. That is the contract's *capture broadly, promote narrowly* falling out
// of the schema rather than being imposed on it.
//
// Derived here rather than sent by the client, so the manifest and the records
// cannot disagree about which scope a row is in — the one place they could
// drift apart, and a drifted `scope_key` would be a foreign key violation at
// best and a miscounted `complete` scope at worst.
export function scopeKeyFor(sourceCode, dataType, action) {
  return action ? `${sourceCode}:${dataType}:${action}` : null;
}

// The scope manifest for one batch.
//
// **Each batch declares only its own scopes, and the run's manifest is their
// union** — `on conflict do nothing` merges them, and the manifest is immutable
// so re-declaring is harmless. That is what lets a batch retried alone still
// name the scopes it needs.
//
// `partial` throughout, never `complete`. Only `complete` licenses expiring an
// item that went missing, and every Apple Music read is capped
// (`maxLibrarySongs`, `maxSongsRated`, `maxPagesPerEndpoint`) — so claiming a
// complete snapshot would be inferring absence from omission, which is the one
// thing §10 forbids outright.
export function scopeManifest(rows) {
  const scopes = new Map();
  for (const row of rows) {
    if (!row.scope_key || scopes.has(row.scope_key)) continue;
    scopes.set(row.scope_key, {
      scope_key: row.scope_key,
      source_code: row.record_source_code,
      data_type: row.data_type,
      action_type: row.action_type,
      snapshot_mode: "full_snapshot",
      completeness: "partial",
    });
  }
  return [...scopes.values()];
}

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

// Sources this endpoint is willing to describe as evidence.
//
// **Calendar and HealthKit are absent on purpose.**
// `private_observation_projection_is_valid_v03` demands a sanitised shape for
// those two — `calendar-v03`, `sanitized_classification`, `action_weight = 0`,
// under 1 KB with a `classification_state` — and that shape is the *output of a
// classifier*, not a transcription of the payload. §7 permits only the current
// Calendar classifier over Calendar rows. Their rows are captured and encrypted
// and contribute zero evidence, which is what §10's Calendar gate asks for.
const PROJECTABLE = new Set(["apple_music", "music_library", "spotify"]);

/**
 * What a music row says, with the capture stripped out.
 *
 * **Deliberately not the whole envelope.** `observed_at` and `ingestion_id`
 * describe *how* a row was collected; an observation is about what was
 * observed. The full envelope stays in the encrypted vault for anything that
 * later wants it — which is the point of keeping raw capture at all.
 *
 * Returns `null` for anything it cannot honestly describe, and the caller sends
 * no observation for those. A row with no title is not evidence of a song.
 */
export function normalizedPayload(sourceCode, payload) {
  if (!PROJECTABLE.has(sourceCode)) return null;
  const value = payload?.kind === "music" ? payload.value : null;
  if (!value) return null;

  const fields = {
    title: value.title,
    primary_performer: value.primaryPerformer,
    credited_artists: value.creditedArtists,
    composer: value.composer,
    album: value.album,
    genres: value.genres,
    release_date: value.releaseDate,
    isrc: value.isrc,
    play_count: value.playCount,
    rank: value.rank,
  };
  for (const [key, held] of Object.entries(fields)) {
    const empty = held === null || held === undefined || held === ""
      || (Array.isArray(held) && held.length === 0);
    if (empty) delete fields[key];
  }
  if (!fields.title) return null;

  fields.schema_version = "music-v03";
  fields.record_kind = "music_item";
  return fields;
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

  // **The fingerprint is taken over the content, never over the capture.**
  // `observed_at` is stamped at distillation and `ingestion_id` is minted per
  // run, so both differ on every pass — leave them in and re-distilling an
  // unchanged library stores every row again, `duplicates` is always 0, and the
  // vault grows without bound while looking perfectly healthy. This is
  // `append_source_records`' own rule, which excludes `collected_at`,
  // `distilled_at` and `updated_at` for exactly this reason and paid for it
  // first. They stay in the *ciphertext*: when a thing was read is a fact
  // worth keeping, it is just not part of what the thing is.
  const { observed_at, ingestion_id, ...content } = sealed;

  // The action decides the scope, and `unweighted_action_type` counts: the
  // server having no weight for `top_track` yet does not stop it being an act.
  const action = envelope.action_type ?? envelope.unweighted_action_type ?? null;

  return {
    record_source_code: sourceCode,
    data_type: dataType,
    action_type: action,
    scope_key: scopeKeyFor(sourceCode, dataType, action),
    occurred_at: occurredAt,
    source_item_hmac: sourceItemHmac(hmacKey, { userId, sourceCode, providerItemId }),
    record_fingerprint: recordFingerprint(hmacKey, {
      userId, sourceCode, dataType, providerItemId, occurredAt, payload: content,
    }),
    encrypted_payload_b64: encryptPayload(dek, canonicalize(sealed)),
    consent_purpose: consentPurposeFor(sourceCode),
    retention_policy_version: RETENTION_POLICY_VERSION,
    // **Evidence, written here because here is where the plaintext is.**
    // `guard_observation_ingestion_run` refuses an observation whose run is not
    // still `running`, and the run closes at finalization — so a worker
    // claiming the job afterwards can never write one. Null for anything this
    // endpoint declines to describe, and the function then stores the raw row
    // alone.
    normalized_payload: normalizedPayload(sourceCode, typedPayload),
    observation_kind: "catalog_item",
    payload_schema_version: "music-v03",
    privacy_class: "public_catalog",
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
