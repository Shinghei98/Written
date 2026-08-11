// The authenticated ingestion endpoint — §4's "private ingestion service".
//
// One job: take a batch of `SourceEnvelope`s from a signed-in device, encrypt
// each payload under a data key that only KMS can unwrap, and hand the
// ciphertext and the wrapped key to Postgres in a single call.
//
// **What it deliberately cannot do.** It runs as `written-semantic-ingestion`,
// which holds `GenerateDataKey`, `Encrypt` and `GenerateMac` and **not**
// `Decrypt`; and it talks to Postgres as `semantic_ingestor`, which can call
// exactly one function and has no table privileges at all. So the thing exposed
// to the internet can write into the vault and cannot read a single row back —
// including the rows it wrote a moment ago. That split is the whole design, and
// both halves are verified by simulation and by connecting rather than by
// reading policy JSON.
//
// **No shared secret with Supabase.** The caller's access token is verified
// against the project's published JWKS, so the user id comes from a signature
// over a public key rather than from anything this function holds. That is what
// made hosting here viable at all.
//
// Dependencies: `pg`, and nothing else. The AWS SDK v3 clients are the ones the
// Node 22 runtime bundles; the JWT is verified with Web Crypto. That follows
// `supabase/functions/push`, which takes no imports whatsoever, as far as it can
// be followed — the Postgres wire protocol is the one thing `fetch` cannot do.

import { KMSClient, GenerateDataKeyCommand, GenerateMacCommand } from "@aws-sdk/client-kms";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import pg from "pg";

import { keyVersionFor, normalizeSource, toRecordRow, InvalidEnvelope } from "./lib.mjs";

const REGION = process.env.AWS_REGION ?? "us-east-1";
const VAULT_KEY_ARN = process.env.VAULT_KEY_ARN;
const LINEAGE_KEY_ARN = process.env.LINEAGE_KEY_ARN;
const DB_SECRET_ID = process.env.DB_SECRET_ID;
const JWKS_URL = process.env.SUPABASE_JWKS_URL;
const ISSUER = process.env.SUPABASE_ISSUER;

// A batch bigger than this is refused rather than truncated. One real Apple
// Music library is ~2,540 rows, so a full distillation is several calls — which
// is what we want anyway: API Gateway caps a request at 10 MB, and a partial
// success is far easier to reason about than a request that silently dropped
// its tail.
const MAX_RECORDS = 500;

// Read once at cold start rather than per connection. Shipped in the bundle:
// fetching it at runtime would mean trusting the network to tell us what to
// trust, which is the thing a pinned root exists to avoid.
const SUPABASE_CA = readFileSync(new URL("./supabase-ca.pem", import.meta.url), "utf8");

const kms = new KMSClient({ region: REGION });
const secrets = new SecretsManagerClient({ region: REGION });

// Module scope, so a warm invocation reuses all three. None of them is a
// per-request fact and each costs a round trip.
let cachedJwks = null;
let cachedDbConfig = null;
let cachedLineageKey = null;

// ---------------------------------------------------------------------------
// Verifying the caller

function b64urlToBuffer(value) {
  return Buffer.from(value.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

function decodeSegment(segment, what) {
  try {
    const decoded = JSON.parse(b64urlToBuffer(segment).toString("utf8"));
    if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) {
      throw new Error("not an object");
    }
    return decoded;
  } catch {
    throw Object.assign(new Error(`unreadable ${what}`), { status: 401 });
  }
}

async function jwks() {
  if (cachedJwks) return cachedJwks;
  const response = await fetch(JWKS_URL);
  if (!response.ok) throw new Error(`JWKS fetch failed: ${response.status}`);
  cachedJwks = (await response.json()).keys ?? [];
  return cachedJwks;
}

/**
 * Verify a Supabase access token and return its subject.
 *
 * **The signature is checked before anything is read out of the payload**,
 * which sounds obvious and is the entire security of this endpoint: `sub` is
 * the user whose vault gets written, so trusting it a moment early means any
 * caller can write into anybody's.
 *
 * A `kid` miss refetches the JWKS exactly once — Supabase rotates signing keys,
 * and a cache that never refreshes turns a rotation into a total outage. A
 * cache that refetches on *every* failure turns a malformed token into a
 * denial-of-service against the JWKS endpoint, which is why it is once.
 */
export async function verifyAccessToken(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw Object.assign(new Error("malformed token"), { status: 401 });
  const [rawHeader, rawPayload, rawSignature] = parts;

  // **A three-part string is not a JWT.** Arity is the only thing checked so
  // far, so anything that survives the split reaches `JSON.parse` — and a bare
  // `SyntaxError` carries no status, falls past every 401 branch and surfaces
  // as a 500. Found by throwing `not.a.token` at the deployed endpoint, not by
  // the unit tests, which only had cases with the wrong number of parts.
  const header = decodeSegment(rawHeader, "header");
  if (header.alg !== "ES256") {
    throw Object.assign(new Error(`unexpected alg ${header.alg}`), { status: 401 });
  }

  let keys = await jwks();
  let jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    cachedJwks = null;
    keys = await jwks();
    jwk = keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) throw Object.assign(new Error("unknown signing key"), { status: 401 });

  const key = await crypto.subtle.importKey(
    "jwk", { ...jwk, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    b64urlToBuffer(rawSignature),
    Buffer.from(`${rawHeader}.${rawPayload}`, "utf8")
  );
  if (!ok) throw Object.assign(new Error("bad signature"), { status: 401 });

  const claims = decodeSegment(rawPayload, "claims");
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== "number" || claims.exp <= now) {
    throw Object.assign(new Error("token expired"), { status: 401 });
  }
  if (ISSUER && claims.iss !== ISSUER) {
    throw Object.assign(new Error("wrong issuer"), { status: 401 });
  }
  if (claims.aud !== "authenticated" || claims.role !== "authenticated") {
    throw Object.assign(new Error("not an authenticated session"), { status: 401 });
  }
  if (typeof claims.sub !== "string" || claims.sub.length === 0) {
    throw Object.assign(new Error("no subject"), { status: 401 });
  }
  return claims.sub;
}

// ---------------------------------------------------------------------------
// Keys

/**
 * A stable HMAC key for `source_item_hmac` and `record_fingerprint`, derived
 * from the lineage KMS key.
 *
 * **One KMS call per invocation, not per record.** `GenerateMac` is
 * deterministic for a given key and message, so MAC'ing a fixed label yields
 * the same sub-key every time, and the records are then HMAC'd locally. A call
 * per record would be 2,540 round trips for one library and would still be
 * deterministic — it just would not finish.
 *
 * **It has to be a different key from the payload key**, which §12 requires:
 * these hashes are computed over predictable inputs, so anybody who obtained
 * the payload key could otherwise test guesses against them.
 */
async function lineageKey() {
  if (cachedLineageKey) return cachedLineageKey;
  const { Mac } = await kms.send(new GenerateMacCommand({
    KeyId: LINEAGE_KEY_ARN,
    MacAlgorithm: "HMAC_SHA_256",
    Message: Buffer.from("written:lineage-subkey:v1", "utf8"),
  }));
  cachedLineageKey = Buffer.from(Mac);
  return cachedLineageKey;
}

/**
 * A data key for this call.
 *
 * **Per call, and that is forced rather than chosen** — this identity has no
 * `Decrypt`, so it cannot recover a key it stored earlier, and a Lambda holds
 * nothing between invocations. `0053` is the database half of the same fact.
 *
 * The encryption context binds the wrapped key to one user: a blob lifted from
 * A's row cannot be unwrapped while claiming to be B, because the worker's
 * `Decrypt` must present the same context.
 */
async function dataKeyFor(userId) {
  const { Plaintext, CiphertextBlob } = await kms.send(new GenerateDataKeyCommand({
    KeyId: VAULT_KEY_ARN,
    KeySpec: "AES_256",
    EncryptionContext: { user_id: userId },
  }));
  return { dek: Buffer.from(Plaintext), wrapped: Buffer.from(CiphertextBlob) };
}

// ---------------------------------------------------------------------------
// Postgres

async function dbConfig() {
  if (cachedDbConfig) return cachedDbConfig;
  const { SecretString } = await secrets.send(new GetSecretValueCommand({ SecretId: DB_SECRET_ID }));
  const parsed = JSON.parse(SecretString);
  cachedDbConfig = {
    host: parsed.host,
    port: Number(parsed.port),
    user: parsed.user,
    password: parsed.password,
    database: parsed.dbname,
    // **Verified against a pinned CA, and the obvious version of this is
    // wrong.** The pooler presents a *self-signed* chain, so plain
    // `rejectUnauthorized: true` fails with `SELF_SIGNED_CERT_IN_CHAIN` — which
    // is exactly the failure that gets "fixed" by setting it to `false`,
    // leaving a connection that carries somebody's whole library encrypted but
    // unauthenticated. Measured, both ways, before choosing.
    //
    // Supabase publishes the root (`Supabase Root 2021 CA`, SHA-256
    // `807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA`), and
    // pinning it moves the failure to `28P01 password authentication failed` —
    // the handshake verifying. **It expires 2031-04-26**, which is an outage
    // with a date on it rather than a surprise.
    ssl: { ca: SUPABASE_CA, rejectUnauthorized: true },
    // Transaction-mode pooling does not support prepared statements. `pg` only
    // uses them for named queries, which this file never issues; the timeouts
    // matter more, because a pooler that is out of upstream connections will
    // otherwise hold the Lambda until it times out at the gateway instead.
    connectionTimeoutMillis: 8000,
    query_timeout: 20000,
    statement_timeout: 20000,
  };
  return cachedDbConfig;
}

async function ingest(rows, context) {
  const client = new pg.Client(await dbConfig());
  await client.connect();
  try {
    const { rows: result } = await client.query(
      `select semantic_private.ingest_source_records_v031(
         $1::uuid, $2::uuid, $3::text, $4::text, $5::text,
         $6::text, $7::text, $8::text, $9::jsonb) as receipt`,
      [
        context.userId, context.ingestionId, context.connectorSource,
        context.connectorVersion, context.inputHash,
        context.keyVersion, context.wrappedDekB64, VAULT_KEY_ARN,
        JSON.stringify(rows),
      ]
    );
    return result[0].receipt;
  } finally {
    await client.end();
  }
}

// ---------------------------------------------------------------------------
// The handler

const json = (statusCode, body) => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

export async function handler(event) {
  let dek = null;
  try {
    const method = event?.requestContext?.http?.method;
    if (method !== "POST") return json(405, { error: "POST only" });

    const auth = event.headers?.authorization ?? event.headers?.Authorization ?? "";
    if (!auth.toLowerCase().startsWith("bearer ")) {
      return json(401, { error: "missing bearer token" });
    }
    const userId = await verifyAccessToken(auth.slice(7).trim());

    const raw = event.isBase64Encoded
      ? Buffer.from(event.body ?? "", "base64").toString("utf8")
      : (event.body ?? "");
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return json(400, { error: "body is not JSON" });
    }

    const records = body?.records;
    if (!Array.isArray(records)) return json(400, { error: "records must be an array" });
    if (records.length > MAX_RECORDS) {
      return json(413, { error: `at most ${MAX_RECORDS} records per call`, received: records.length });
    }
    if (typeof body.ingestion_id !== "string") {
      return json(400, { error: "ingestion_id is required" });
    }

    const connectorSource = normalizeSource(body.connector_source_code);
    if (!connectorSource) {
      return json(400, { error: "unknown connector_source_code" });
    }

    const hmacKey = await lineageKey();
    const generated = await dataKeyFor(userId);
    dek = generated.dek;

    let rows;
    try {
      rows = records.map((envelope, index) =>
        toRecordRow(envelope, index, { userId, hmacKey, dek })
      );
    } catch (error) {
      if (error instanceof InvalidEnvelope) return json(400, { error: error.message });
      throw error;
    }

    const receipt = await ingest(rows, {
      userId,
      ingestionId: body.ingestion_id,
      connectorSource,
      connectorVersion: String(body.connector_version ?? "unknown"),
      inputHash: String(body.input_hash ?? "unknown"),
      keyVersion: keyVersionFor(randomUUID()),
      wrappedDekB64: generated.wrapped.toString("base64"),
    });

    return json(200, receipt);
  } catch (error) {
    // **Never echo the message on a 500.** A Postgres error from this path can
    // carry a constraint name, a column list, and in the worst case a fragment
    // of the statement — which is a description of the vault's shape handed to
    // whoever provoked it. It goes to CloudWatch, where the operator can read
    // it, and the caller gets a bare code.
    // **The refusal reason goes to the log, never to the caller.** Telling a
    // stranger *why* their token was rejected is a probing oracle; telling
    // nobody at all is how the first real device request became unexplainable
    // — the invocation was there in CloudWatch, the vault was empty, and
    // nothing anywhere said which check had failed. `functions/push` learned
    // this the same way: anything the function needs to say has to travel
    // somewhere the operator can actually read.
    if (error?.status === 401) {
      console.error("rejected token:", error.message);
      return json(401, { error: "unauthorized" });
    }
    if (error?.status === 400) return json(400, { error: error.message });
    console.error("ingestion failed", error);
    return json(500, { error: "ingestion failed" });
  } finally {
    // The plaintext key is the one thing here that must not outlive the call.
    // A `Buffer` is not garbage collected promptly and Lambda reuses the
    // execution environment, so it is overwritten rather than dropped.
    if (dek) dek.fill(0);
  }
}
