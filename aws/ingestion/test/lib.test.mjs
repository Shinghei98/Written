// The pure half of the ingestion endpoint.
//
// These are the mistakes that would not show up in an integration test. A row
// appearing in the vault proves nothing about whether its fingerprint is stable
// across encoders, whether its item hash leaks who shares a library with whom,
// or whether the caller got to choose its own consent purpose.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv } from "node:crypto";

import {
  canonicalize, consentPurposeFor, encryptPayload, InvalidEnvelope, keyVersionFor,
  normalizeSource, recordFingerprint, sourceItemHmac, toRecordRow,
} from "../lib.mjs";

const KEY = Buffer.alloc(32, 7);
const DEK = Buffer.alloc(32, 9);
const USER = "11111111-1111-1111-1111-111111111111";

test("canonical form does not depend on key order", () => {
  assert.equal(
    canonicalize({ b: 1, a: { d: 2, c: [3, { f: 4, e: 5 }] } }),
    canonicalize({ a: { c: [3, { e: 5, f: 4 }], d: 2 }, b: 1 })
  );
});

test("canonical form still distinguishes different content", () => {
  assert.notEqual(canonicalize({ a: 1 }), canonicalize({ a: 2 }));
  assert.notEqual(canonicalize({ a: "1" }), canonicalize({ a: 1 }));
  // A dropped key and a null one are different facts — an absent composer and
  // a source that returned none are not the same observation.
  assert.notEqual(canonicalize({ a: 1 }), canonicalize({ a: 1, b: null }));
});

test("the same item hashes the same way every run", () => {
  const args = { userId: USER, sourceCode: "apple_music", providerItemId: "i.123" };
  assert.equal(sourceItemHmac(KEY, args), sourceItemHmac(KEY, args));
  assert.match(sourceItemHmac(KEY, args), /^[0-9a-f]{64}$/);
});

test("two users with the same item do not share a hash", () => {
  // Without the salt, anybody holding the database learns who shares a library
  // with whom, from a column that exists to avoid holding anything identifying.
  const a = sourceItemHmac(KEY, { userId: USER, sourceCode: "apple_music", providerItemId: "i.1" });
  const b = sourceItemHmac(KEY, { userId: "22222222-2222-2222-2222-222222222222", sourceCode: "apple_music", providerItemId: "i.1" });
  assert.notEqual(a, b);
});

test("the fingerprint is stable under key order and changes with content", () => {
  const base = {
    userId: USER, sourceCode: "apple_music", dataType: "library_song",
    providerItemId: "i.1", occurredAt: null,
  };
  assert.equal(
    recordFingerprint(KEY, { ...base, payload: { title: "A", artist: "B" } }),
    recordFingerprint(KEY, { ...base, payload: { artist: "B", title: "A" } })
  );
  assert.notEqual(
    recordFingerprint(KEY, { ...base, payload: { title: "A" } }),
    recordFingerprint(KEY, { ...base, payload: { title: "B" } })
  );
  assert.match(recordFingerprint(KEY, { ...base, payload: {} }), /^[0-9a-f]{64}$/);
});

test("ciphertext round-trips and never reuses an IV", () => {
  const sealed = encryptPayload(DEK, '{"title":"A"}');
  const raw = Buffer.from(sealed, "base64");
  const iv = raw.subarray(0, 12);
  const tag = raw.subarray(raw.length - 16);
  const body = raw.subarray(12, raw.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", DEK, iv);
  decipher.setAuthTag(tag);
  assert.equal(Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8"), '{"title":"A"}');

  // GCM fails catastrophically on a repeated (key, IV) pair, and the DEK is
  // reused across every record in a call.
  const ivs = new Set(
    Array.from({ length: 200 }, () => Buffer.from(encryptPayload(DEK, "x"), "base64").subarray(0, 12).toString("hex"))
  );
  assert.equal(ivs.size, 200);
});

test("a tampered tag is rejected rather than silently decrypted", () => {
  const raw = Buffer.from(encryptPayload(DEK, '{"a":1}'), "base64");
  raw[raw.length - 1] ^= 0xff;
  const decipher = createDecipheriv("aes-256-gcm", DEK, raw.subarray(0, 12));
  decipher.setAuthTag(raw.subarray(raw.length - 16));
  assert.throws(() => {
    decipher.update(raw.subarray(12, raw.length - 16));
    decipher.final();
  });
});

test("health is translated and unknown sources are refused", () => {
  assert.equal(normalizeSource("health"), "healthkit");
  assert.equal(normalizeSource("apple_music"), "apple_music");
  assert.equal(normalizeSource("tiktok"), null);
  assert.equal(normalizeSource(undefined), null);
});

test("the consent purpose follows the source, never the caller", () => {
  assert.equal(consentPurposeFor("healthkit"), "fitness_connection");
  assert.equal(consentPurposeFor("apple_calendar"), "calendar_distillation");
  assert.equal(consentPurposeFor("google_calendar"), "calendar_distillation");
  assert.equal(consentPurposeFor("apple_music"), "source_distillation");

  // A client that could choose would file HealthKit under source_distillation
  // and step around the grant the contract wants that transfer gated on.
  const row = toRecordRow(
    { record_source_code: "health", data_type: "workout", provider_item_id: "w1",
      consent_purpose: "source_distillation", typed_payload: { kind: "workout" } },
    0, { userId: USER, hmacKey: KEY, dek: DEK }
  );
  assert.equal(row.consent_purpose, "fitness_connection");
  assert.equal(row.record_source_code, "healthkit");
});

test("a bad envelope is refused with the offending index", () => {
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const bad = [
    [{ record_source_code: "nope", data_type: "x", provider_item_id: "1" }, /unknown record_source_code/],
    [{ record_source_code: "user", data_type: "Bad-Type", provider_item_id: "1" }, /data_type/],
    [{ record_source_code: "user", data_type: "bio", provider_item_id: "" }, /provider_item_id/],
    [{ record_source_code: "user", data_type: "bio", provider_item_id: "1", source_event_at: "not a date" }, /source_event_at/],
  ];
  for (const [envelope, pattern] of bad) {
    assert.throws(() => toRecordRow(envelope, 3, ctx), (error) => {
      assert.ok(error instanceof InvalidEnvelope);
      assert.equal(error.index, 3);
      assert.match(error.message, pattern);
      return true;
    });
  }
});

test("the key version is storable by the column that names it", () => {
  // 0051 aligned this pattern with raw_source_records.encryption_key_version.
  // A version refused here is better than one Postgres refuses after the
  // payload has already been encrypted under it.
  const version = keyVersionFor("0f8fad5b-d9cb-469f-a165-70867728950e");
  assert.match(version, /^[a-z0-9][a-z0-9_.-]{0,63}$/);
  assert.throws(() => keyVersionFor("NOT/A/UUID"));
});

test("re-sending the same envelope produces the same fingerprint", () => {
  // This is what makes a retry idempotent at the unique index rather than at
  // the client — the ciphertext differs every time, because the IV does, so
  // the fingerprint must be computed over the plaintext.
  const envelope = {
    record_source_code: "apple_music", data_type: "library_song",
    provider_item_id: "i.1", typed_payload: { title: "A", artists: ["B"] },
  };
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const first = toRecordRow(envelope, 0, ctx);
  const second = toRecordRow(envelope, 0, ctx);
  assert.equal(first.record_fingerprint, second.record_fingerprint);
  assert.equal(first.source_item_hmac, second.source_item_hmac);
  assert.notEqual(first.encrypted_payload_b64, second.encrypted_payload_b64);
});

test("re-distilling an unchanged item is a duplicate, not a new row", () => {
  // **The defect this catches would have looked perfectly healthy.**
  // `observed_at` is stamped at distillation and `ingestion_id` is minted per
  // run, so both differ on every pass. Fingerprinting over them means every
  // re-distill stores every row again, `duplicates` reads 0 forever, and the
  // vault grows without bound while every number on the dashboard looks right.
  // `append_source_records` excludes collected_at/distilled_at/updated_at for
  // exactly this reason and paid for it first.
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const base = {
    record_source_code: "apple_music", data_type: "library_song",
    provider_item_id: "i.1", typed_payload: { title: "A" },
  };
  const monday = toRecordRow(
    { ...base, observed_at: "2026-08-01T10:00:00Z", ingestion_id: "run-1" }, 0, ctx);
  const tuesday = toRecordRow(
    { ...base, observed_at: "2026-08-02T22:31:04Z", ingestion_id: "run-2" }, 0, ctx);
  assert.equal(monday.record_fingerprint, tuesday.record_fingerprint);

  // But a real change is still a new row — the append-only reading.
  const changed = toRecordRow(
    { ...base, observed_at: "2026-08-02T22:31:04Z", ingestion_id: "run-2",
      typed_payload: { title: "A", playCount: 9 } }, 0, ctx);
  assert.notEqual(monday.record_fingerprint, changed.record_fingerprint);
});
