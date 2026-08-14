// The pure half of the ingestion endpoint.
//
// These are the mistakes that would not show up in an integration test. A row
// appearing in the vault proves nothing about whether its fingerprint is stable
// across encoders, whether its item hash leaks who shares a library with whom,
// or whether the caller got to choose its own consent purpose.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv, createHmac } from "node:crypto";

import {
  canonicalize, consentPurposeFor, contentFingerprint, encryptPayload, fingerprintContent, ingestArguments, InvalidEnvelope, keyVersionFor, normalizedPayload, normalizeSource, projectionDiagnostic, recordFingerprint, scopeManifest, sourceItemHmac, toRecordRow, calendarEventsFor, applyCalendarProjections, CALENDAR_SOURCES,
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

test("every calendar is a calendar to all three of these lists", () => {
  // `outlook_calendar` was in the Swift enum, in
  // `AppConfig.semanticIngestionSources` and in `0133`'s
  // `is_private_calendar_source`, and in none of the three lists here. Each
  // omission fails differently and all three fail quietly: the source list
  // refuses the batch 400 and the client drops it; the purpose would file
  // whole calendar events under `source_distillation`, which is the general
  // grant rather than the one the vault exists for; and the classifier set
  // decides whether a calendar row ever becomes evidence at all.
  for (const calendar of ["apple_calendar", "google_calendar", "outlook_calendar"]) {
    assert.equal(normalizeSource(calendar), calendar, `${calendar} is accepted`);
    assert.equal(
      consentPurposeFor(calendar), "calendar_distillation",
      `${calendar} is captured under the calendar grant`,
    );
    assert.ok(CALENDAR_SOURCES.has(calendar), `${calendar} reaches the classifier`);
  }
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

test("a scope is (source, data_type, action), and no action means no scope", () => {
  // `ingestion_run_scopes.action_type` is not null, so a record carrying no
  // action belongs to no scope, gets no run item, and is never promoted. Still
  // captured, still encrypted — simply not evidence. Capture broadly, promote
  // narrowly, falling out of the schema rather than imposed on it.
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const song = toRecordRow({ record_source_code: "apple_music", data_type: "library_song",
    action_type: "library_song", provider_item_id: "i.1", typed_payload: {} }, 0, ctx);
  assert.equal(song.scope_key, "apple_music:library_song:library_song");

  const bio = toRecordRow({ record_source_code: "user", data_type: "bio",
    provider_item_id: "bio", typed_payload: {} }, 0, ctx);
  assert.equal(bio.scope_key, null);
  assert.equal(bio.action_type, null);

  // An action the server does not weigh yet is still an action.
  const top = toRecordRow({ record_source_code: "spotify", data_type: "top_track",
    unweighted_action_type: "top_track", provider_item_id: "t.1", typed_payload: {} }, 0, ctx);
  assert.equal(top.scope_key, "spotify:top_track:top_track");
});

test("the manifest is the batch's distinct scopes, always partial", () => {
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const rows = [
    { record_source_code: "apple_music", data_type: "library_song", action_type: "library_song", provider_item_id: "a", typed_payload: {} },
    { record_source_code: "apple_music", data_type: "library_song", action_type: "library_song", provider_item_id: "b", typed_payload: {} },
    { record_source_code: "apple_music", data_type: "rating", action_type: "rating", provider_item_id: "c", typed_payload: {} },
    { record_source_code: "user", data_type: "bio", provider_item_id: "d", typed_payload: {} },
  ].map((e, i) => toRecordRow(e, i, ctx));

  const scopes = scopeManifest(rows);
  assert.equal(scopes.length, 2, "two scopes; the unscoped bio contributes none");
  // **Never `complete`.** Only complete licenses expiring a missing item, and
  // every Apple Music read is capped — so complete would be inferring absence
  // from omission, which §10 forbids outright.
  assert.ok(scopes.every((s) => s.completeness === "partial"));
  assert.ok(scopes.every((s) => /^[a-z0-9][a-z0-9_.:-]{0,127}$/.test(s.scope_key)));
});

test("only describable rows become evidence", () => {
  // Calendar and HealthKit are captured and contribute nothing: their sanitised
  // shape is a classifier's output, not a transcription, and §7 permits only
  // the current Calendar classifier over Calendar rows.
  assert.equal(normalizedPayload("apple_calendar", { kind: "calendar", value: { title: "X" } }), null);
  assert.equal(normalizedPayload("healthkit", { kind: "fitness", value: { kind: "workout" } }), null);

  // A row with no title is not evidence of a song.
  assert.equal(normalizedPayload("apple_music", { kind: "music", value: { album: "A" } }), null);

  const fields = normalizedPayload("apple_music", {
    kind: "music",
    value: { title: "Partita No. 2", composer: "J.S. Bach", primaryPerformer: "Itzhak Perlman",
             genres: [], album: null, creditedArtists: ["Itzhak Perlman"] },
  });
  assert.equal(fields.title, "Partita No. 2");
  assert.equal(fields.composer, "J.S. Bach");
  assert.equal(fields.schema_version, "music-v03");
  // Absent and empty are the same thing to a resolver, and the private sources
  // are held to 1 KB — a limit worth respecting everywhere.
  assert.ok(!("genres" in fields) && !("album" in fields));
});

test("the same song encoded two ways has one fingerprint", () => {
  // **The property that cost a full re-store to learn.** The fingerprint used
  // to be taken over the canonicalised envelope, so `schema_version` and the
  // payload's shape were part of a record's identity — and moving from Swift's
  // synthesised `{"music":{"_0":…}}` to `{"kind":…,"value":…}` turned 1,227
  // vault rows into 2,441 without a byte of anybody's library changing.
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const song = { title: "Partita No. 2", composer: "J.S. Bach" };
  const common = {
    record_source_code: "apple_music", data_type: "library_song",
    action_type: "library_song", provider_item_id: "i.1",
  };
  const v1 = toRecordRow(
    { ...common, schema_version: "written-source-envelope-v1",
      typed_payload: { music: { _0: song } } }, 0, ctx);
  const v2 = toRecordRow(
    { ...common, schema_version: "written-source-envelope-v2",
      typed_payload: { kind: "music", value: song } }, 0, ctx);
  assert.equal(v1.record_fingerprint, v2.record_fingerprint);

  // And a real content change is still a different record.
  const changed = toRecordRow(
    { ...common, schema_version: "written-source-envelope-v2",
      typed_payload: { kind: "music", value: { ...song, playCount: 9 } } }, 0, ctx);
  assert.notEqual(v2.record_fingerprint, changed.record_fingerprint);
});

test("an unrecognised payload shape is hashed whole, never reduced", () => {
  // The failure this guards against is silent and unrecoverable: a payload
  // shape the unwrapper does not know, reduced to one of its fields, makes two
  // genuinely different records hash the same — and the second is skipped as a
  // duplicate and lost.
  const a = fingerprintContent({ typed_payload: { title: "A" } });
  const b = fingerprintContent({ typed_payload: { title: "A", playCount: 9 } });
  assert.notDeepEqual(a, b);
  assert.deepEqual(a.payload, { title: "A" }, "hashed whole, not reduced");

  // Two keys is not v1 either, even if one of them looks like a case.
  const two = fingerprintContent({ typed_payload: { music: { _0: { t: 1 } }, extra: 2 } });
  assert.deepEqual(two.payload, { music: { _0: { t: 1 } }, extra: 2 });
});

test("a failed endpoint declares an empty truncated scope", () => {
  // A data type whose endpoint failed produces no rows, so without this the run
  // simply looks smaller and nothing records that anything was lost. "Asked and
  // got nothing" is a different fact from "never looked".
  const scopes = scopeManifest([], [
    { source_code: "apple_music", data_type: "library_song", action_type: "library_song" },
  ]);
  assert.equal(scopes.length, 1);
  assert.equal(scopes[0].completeness, "truncated");
  assert.equal(scopes[0].scope_key, "apple_music:library_song:library_song");

  // A type that both failed and returned rows keeps the truncated reading —
  // partial data is still short data, and the stronger claim must not win.
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const row = toRecordRow({ record_source_code: "apple_music", data_type: "library_song",
    action_type: "library_song", provider_item_id: "i.1", typed_payload: {} }, 0, ctx);
  const both = scopeManifest([row], [
    { source_code: "apple_music", data_type: "library_song", action_type: "library_song" },
  ]);
  assert.equal(both.length, 1);
  assert.equal(both[0].completeness, "truncated");
});

test("the database call's arguments build without touching a database", () => {
  // This exists because a ReferenceError lived in that call — it reached for
  // `body`, a local of another function — and every ingestion returned 500
  // until a real request found it. The tests covered pure transforms and token
  // verification and never executed the query path at all.
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const rows = [toRecordRow({ record_source_code: "apple_music", data_type: "library_song",
    action_type: "library_song", provider_item_id: "i.1", typed_payload: {} }, 0, ctx)];

  const args = ingestArguments({
    userId: USER, ingestionId: "run-1", connectorSource: "apple_music",
    connectorVersion: "ios-1.0", inputHash: "h", keyVersion: "dek-1",
    wrappedDekB64: "AAA=", final: true,
  }, rows, "arn:aws:kms:us-east-1:1:key/x");

  assert.equal(args.length, 12, "the function takes twelve arguments, in order");
  assert.equal(args[0], USER);
  assert.equal(args[10], true, "final");
  assert.equal(args[11], null, "no coverage sent is null, not an empty object");
  assert.equal(JSON.parse(args[8]).length, 1, "one scope from one row");
  assert.equal(JSON.parse(args[9]).length, 1, "one record");

  // Absent `truncated` must not throw — the common case is no shortfall.
  assert.doesNotThrow(() => ingestArguments({ userId: USER }, [], "arn"));

  // The device's own account of the run travels untouched: a disagreement
  // between what it believed it sent and what landed is the whole point of a
  // shadow phase, so the server must not tidy either half.
  const withCoverage = ingestArguments(
    { userId: USER, coverage: { legacy_records: 1332, envelopes: 1214 } }, [], "arn");
  assert.deepEqual(JSON.parse(withCoverage[11]), { legacy_records: 1332, envelopes: 1214 });
});

test("a row with no projection carries no observation fields at all", () => {
  // JSON `null` is not SQL NULL. Sent as null, `-> 'normalized_payload'` makes
  // it `'null'::jsonb`, which passed an `is not null` guard and then failed the
  // closed-projection check — taking a whole Calendar run's capture with it.
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const calendar = toRecordRow({ record_source_code: "apple_calendar", data_type: "event",
    action_type: "booked", provider_item_id: "e.1",
    typed_payload: { kind: "calendar", value: { title: "X" } } }, 0, ctx);
  assert.ok(!("normalized_payload" in calendar), "omitted, not null");
  assert.ok(!("observation_kind" in calendar));
  assert.ok(!("privacy_class" in calendar));

  const song = toRecordRow({ record_source_code: "apple_music", data_type: "library_song",
    action_type: "library_song", provider_item_id: "i.1",
    typed_payload: { kind: "music", value: { title: "A" } } }, 0, ctx);
  assert.equal(song.normalized_payload.title, "A");
  assert.equal(song.privacy_class, "public_catalog");
});

// ---------------------------------------------------------------------------
// Calendar projections
//
// The classifier runs in another process, so what is testable here is the join:
// which events get sent, how verdicts are matched back, and the vocabulary the
// observation is given. `0064` exists because that vocabulary is not the
// record's, and getting it wrong fails the whole batch rather than one row.

test("calendarEventsFor sends only calendar rows, keyed by fingerprint", () => {
  const envelopes = [
    { record_source_code: "apple_music", typed_payload: { value: { title: "x" } } },
    { record_source_code: "apple_calendar", provider_item_id: "ev-9",
      typed_payload: { value: { title: "Ticket: Hamilton" } } },
  ];
  const rows = [
    { record_source_code: "apple_music", record_fingerprint: "a" },
    { record_source_code: "apple_calendar", record_fingerprint: "b" },
  ];
  const events = calendarEventsFor(envelopes, rows);
  assert.equal(events.length, 1);
  assert.equal(events[0].ref, "b");
  assert.equal(events[0].item_id, "ev-9");
  assert.equal(events[0].payload.title, "Ticket: Hamilton");
});

test("a candidate gets the projection fields, and the weight the constraint pins", () => {
  // The row already says `calendar_event` — the device sends it that way,
  // because the run-item guard requires record, scope and observation to agree.
  const rows = [{
    record_source_code: "apple_calendar", record_fingerprint: "b",
    data_type: "calendar_event", action_type: "booked",
    occurred_at: "2026-09-02T19:00:00.000Z",
  }];
  const applied = applyCalendarProjections(rows, {
    b: {
      classification_state: "candidate",
      content_lineage_hmac: "f".repeat(64),
      normalized_payload: {
        schema_version: "calendar-v03", record_kind: "calendar_classification",
        classification_state: "candidate", artifact_type: "public_ticket",
      },
    },
  });
  assert.equal(applied, 1);
  const row = rows[0];
  assert.equal(row.data_type, "calendar_event");
  // **Not overridden.** `guard_ingestion_run_item_v031` requires the
  // observation's data type and action to equal the scope's, so a projection
  // that renamed either would be refused after the rows were already encrypted.
  assert.equal(row.observation_data_type, undefined);
  assert.equal(row.observation_action_type, undefined);
  // The one genuine divergence: `sources` weighs `scheduled` 0.9 and the
  // Calendar projection is pinned at exactly zero.
  assert.equal(row.observation_action_weight, 0);
  assert.equal(row.observation_kind, "sanitized_classification");
  assert.equal(row.privacy_class, "private_calendar_sanitized");
  assert.equal(row.content_lineage_hmac, "f".repeat(64));
});

test("an excluded row still gets a weight of zero", () => {
  const rows = [{
    record_source_code: "apple_calendar", record_fingerprint: "b",
    action_type: "scheduled", occurred_at: "2026-09-02T19:00:00.000Z",
  }];
  applyCalendarProjections(rows, {
    b: { classification_state: "excluded", normalized_payload: {
      schema_version: "calendar-v03", record_kind: "calendar_classification",
      classification_state: "excluded" } },
  });
  assert.equal(rows[0].observation_action_weight, 0);
  assert.equal(rows[0].content_lineage_hmac, null);
});

test("a candidate with no capture time is downgraded to review", () => {
  // The observation takes its time from the record, and the constraint demands
  // one for a candidate. Sending it anyway fails the whole batch.
  const rows = [{
    record_source_code: "apple_calendar", record_fingerprint: "b",
    action_type: "booked", occurred_at: null,
  }];
  applyCalendarProjections(rows, {
    b: {
      classification_state: "candidate",
      content_lineage_hmac: "f".repeat(64),
      normalized_payload: {
        schema_version: "calendar-v03", record_kind: "calendar_classification",
        classification_state: "candidate", artifact_type: "travel_itinerary",
      },
    },
  });
  assert.equal(rows[0].normalized_payload.classification_state, "review");
  assert.equal(rows[0].normalized_payload.artifact_type, undefined);
  assert.equal(rows[0].content_lineage_hmac, null);
});

test("a row the classifier said nothing about is left alone", () => {
  // The classifier being unavailable must leave the row capturable, which is
  // what Calendar did before any of this existed.
  const rows = [{ record_source_code: "apple_calendar", record_fingerprint: "b" }];
  assert.equal(applyCalendarProjections(rows, {}), 0);
  assert.equal(rows[0].normalized_payload, undefined);
});

// ---------------------------------------------------------------------------
// YouTube: what the projection must never carry
// ---------------------------------------------------------------------------

const YT = {
  kind: "video",
  value: {
    title: "Matthaus-Passion, BWV 244: Nr.1 Kommt, ihr Toechter",
    channelTitle: "Raphael Pichon",
    channelID: "UCabc-123_XYZ",
    description: "Recorded live at the Philharmonie de Paris",
    playlistTitle: "Bach favourites",
    topics: ["Music", "Classical_music"],
    tags: ["bach", "st matthew passion"],
    categoryID: "10",
    subscriberCount: "1230000",
  },
};

test("the YouTube projection carries labels and never text", () => {
  const fields = normalizedPayload("youtube", YT);

  // The whole point. Every one of these is "video titles, creator names,
  // descriptions" under III.E.4, must be deleted or refreshed within 30 days,
  // and lands in a column `guard_observation_immutable` freezes — so a title
  // reaching here could never be removed.
  for (const forbidden of ["title", "channel_title", "channelTitle",
                           "description", "playlist_title", "playlistTitle"]) {
    assert.ok(!(forbidden in fields), `${forbidden} must not be projected`);
  }

  assert.deepEqual(fields.topics, ["Music", "Classical_music"]);
  assert.deepEqual(fields.tags, ["bach", "st matthew passion"]);
  assert.equal(fields.category_id, "10");
  assert.equal(fields.channel_id, "UCabc-123_XYZ");
  assert.equal(fields.subscriber_count, "1230000");
  assert.equal(fields.schema_version, "youtube-v03");
  assert.equal(fields.record_kind, "youtube_labels");

  // Closed by subtraction server-side, so the client must send nothing else:
  // `0082` refuses the row outright if it does, which fails the insert.
  assert.deepEqual(Object.keys(fields).sort(), [
    "category_id", "channel_id", "record_kind", "schema_version",
    "subscriber_count", "tags", "topics",
  ]);
});

test("a topic that is really a title is dropped, not projected", () => {
  // The server pattern has no space in it; the client filters to match rather
  // than sending a row the guard will refuse and failing the whole batch.
  const fields = normalizedPayload("youtube", {
    kind: "video",
    value: { topics: ["LE SSERAFIM Stage Mix 4K", "Music"], tags: [] },
  });
  assert.deepEqual(fields.topics, ["Music"]);
});

test("a multi-word tag survives, a control character does not", () => {
  // `le sserafim` is the tag the whole uploader_tag path exists to carry, and
  // the first control-character class written here was a space-to-hyphen range
  // that would have dropped it along with every other multi-word tag.
  const fields = normalizedPayload("youtube", {
    kind: "video",
    value: { topics: ["Music"], tags: ["le sserafim", "kpop\u0007stage"] },
  });
  assert.deepEqual(fields.tags, ["le sserafim"]);
});

test("a YouTube row with no label at all is not an observation", () => {
  // An identifier says nothing on its own. `0082` requires one of topics, tags
  // or category_id, and a row carrying only a channel id describes nothing.
  assert.equal(normalizedPayload("youtube", {
    kind: "video",
    value: { channelID: "UCabc123", subscriberCount: "5", topics: [], tags: [] },
  }), null);
});

test("a YouTube row is stamped with YouTube's vocabulary, not music's", () => {
  const ctx = { userId: USER, hmacKey: KEY, dek: DEK };
  const row = toRecordRow({ record_source_code: "youtube", data_type: "subscription",
    action_type: "subscription", provider_item_id: "UCabc-123_XYZ",
    typed_payload: YT }, 0, ctx);
  assert.equal(row.observation_kind, "provider_labels");
  assert.equal(row.payload_schema_version, "youtube-v03");
  assert.equal(row.privacy_class, "public_catalog");
});

test("the projection diagnostic reports shapes and never content", () => {
  const rows = [
    { record_source_code: "apple_calendar", data_type: "calendar_event",
      action_type: "booked", observation_kind: "sanitized_classification",
      privacy_class: "private_calendar_sanitized",
      payload_schema_version: "calendar-v03",
      occurred_at: "2026-08-01T00:00:00Z", content_lineage_hmac: "a".repeat(64),
      observation_action_weight: 0,
      normalized_payload: { schema_version: "calendar-v03",
        record_kind: "calendar_classification",
        classification_state: "candidate", artifact_type: "public_ticket" } },
    // Same shape, different content — must collapse into the first.
    { record_source_code: "apple_calendar", data_type: "calendar_event",
      action_type: "booked", observation_kind: "sanitized_classification",
      privacy_class: "private_calendar_sanitized",
      payload_schema_version: "calendar-v03",
      occurred_at: "2026-09-09T00:00:00Z", content_lineage_hmac: "b".repeat(64),
      observation_action_weight: 0,
      normalized_payload: { schema_version: "calendar-v03",
        record_kind: "calendar_classification",
        classification_state: "candidate", artifact_type: "public_ticket" } },
    // A row with no projection is not an observation and is not reported.
    { record_source_code: "apple_calendar", data_type: "calendar", action_type: null },
  ];

  const out = projectionDiagnostic(rows);
  assert.equal(out.length, 1, "identical shapes collapse");
  assert.equal(out[0].count, 2);
  assert.deepEqual(out[0].payload_keys,
    ["artifact_type", "classification_state", "record_kind", "schema_version"]);
  assert.equal(out[0].occurred_at, "present");
  assert.equal(out[0].content_lineage_hmac, "present");

  // The whole safety property: no value from any field appears in the output.
  const text = JSON.stringify(out);
  for (const secret of ["public_ticket".length && "2026-09-09", "a".repeat(64)]) {
    assert.ok(!text.includes(secret), `leaked ${secret}`);
  }
});

test("a differing shape is reported separately", () => {
  const base = { record_source_code: "apple_calendar", data_type: "calendar_event",
    action_type: "booked", observation_kind: "sanitized_classification",
    privacy_class: "private_calendar_sanitized",
    payload_schema_version: "calendar-v03", occurred_at: null,
    content_lineage_hmac: null, observation_action_weight: 0,
    normalized_payload: { schema_version: "calendar-v03",
      record_kind: "calendar_classification", classification_state: "excluded" } };
  const out = projectionDiagnostic([base, { ...base, action_type: "scheduled" }]);
  assert.equal(out.length, 2, "a different action is a different shape");
  assert.deepEqual(out.map((o) => o.action).sort(), ["booked", "scheduled"]);
});

test("a title yields its hashtags and never itself", () => {
  // The whole point: the sentence is read and dropped, the tokens are kept.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: 'Sheldon ran a red light and received a court summons #youngsheldon #shorts',
    topics: ["Entertainment"],
  }});
  assert.deepEqual(projected.title_hashtags, ["youngsheldon", "shorts"]);
  assert.equal(JSON.stringify(projected).includes("court summons"), false);
  assert.equal("title" in projected, false);
});

test("hashtags carry Hangul and CJK, and repeat only once", () => {
  // `르세라핌` is the commonest tag on the account this was built from, and a
  // JavaScript \w would have dropped every one of them.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: "#르세라핌 #LE_SSERAFIM #르세라핌 #le_sserafim #安可",
  }});
  assert.deepEqual(projected.title_hashtags,
    ["르세라핌", "LE_SSERAFIM", "安可"]);
});

test("a title with no hashtag projects no field at all", () => {
  // An empty array would be a claim that the uploader tagged nothing, which is
  // different from a title that simply is not tagged.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: "Beethoven Symphony No. 9", topics: ["Music"],
  }});
  assert.equal("title_hashtags" in projected, false);
});

test("a hashtag alone is a label, so the row is an observation", () => {
  // `youtubeLabels` refuses a projection with no label — an id identifies
  // without saying anything. A hashtag says something, so it must count.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    channelID: "UCabc123", title: "#babymonster",
  }});
  assert.notEqual(projected, null);
  assert.deepEqual(projected.title_hashtags, ["babymonster"]);
});

test("the real SAO video yields the work and never the sentence", () => {
  // The exact title measured on the account this lane was built for, and the
  // reason it exists: nothing else in the projection says Sword Art Online.
  // The channel is Netflix Japan, the topics are containers, the tags empty.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: "名戦3選 - 黒の剣士キリトと閃光のアスナの軌跡 | ソードアート・オンライン | Netflix Japan",
    channelID: "UCnetflixjp",
  }});
  assert.deepEqual(projected.title_works, ["work:sword_art_online"]);
  assert.equal(JSON.stringify(projected).includes("キリト"), false);
  assert.equal(JSON.stringify(projected).includes("Netflix"), false);
  assert.equal("title" in projected, false);
});

test("a work alone is a label, so the row is an observation", () => {
  // The SAO row carries no tags, no topics and no category. Leaving
  // `title_works` out of the guard would drop the one row this lane is for.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: "ソードアート・オンライン", channelID: "UCabc123",
  }});
  assert.notEqual(projected, null);
  assert.deepEqual(projected.title_works, ["work:sword_art_online"]);
});

test("the most specific work wins, so one video is not counted twice", () => {
  // Every title naming SAO II also names SAO. Emitting both would inflate a
  // work whose whole difficulty is that it sits just under the bar.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: "Sword Art Online II - Best Fights", channelID: "UCx",
  }});
  assert.deepEqual(projected.title_works, ["work:sword_art_online_ii"]);
});

test("a word that is also a work is not a work", () => {
  // `bleach`, `fate` and `persona` are ordinary words. Matching them would
  // attach a series to somebody who never watched it, which is the failure
  // this catalogue refuses by leaving the bare forms out.
  for (const title of [
    "How to clean grout with bleach and baking soda",
    "The fate of the Roman Republic, explained",
    "Carl Jung and the persona - a short introduction",
  ]) {
    const projected = normalizedPayload("youtube", { kind: "video", value: {
      title, topics: ["Education"],
    }});
    assert.equal("title_works" in projected, false, title);
  }
});

test("a Latin work title is matched at its edges", () => {
  // `swords art online` is not the show, and a containment test would say
  // it was.
  const projected = normalizedPayload("youtube", { kind: "video", value: {
    title: "Crosswords art online puzzle stream", topics: ["Gaming"],
  }});
  assert.equal("title_works" in projected, false);
});

test("a projector bump re-stores one source and leaves the others alone", () => {
  // **The property that makes this safe to run against production.** A source
  // absent from PROJECTOR_VERSIONS must hash exactly as it did before the map
  // existed, or a change aimed at YouTube re-stores every music row too.
  const key = Buffer.from("k".repeat(32));
  const base = {
    userId: "u", dataType: "liked_video", providerItemId: "vid1",
    occurredAt: "2026-08-14T00:00:00Z", payload: { a: 1 },
  };
  const expectedWithout = createHmac("sha256", key)
    .update(`written:record:v1\nu\napple_music\nliked_video\nvid1\n` +
            `2026-08-14T00:00:00Z\n${canonicalize({ a: 1 })}`)
    .digest("hex");
  assert.equal(
    recordFingerprint(key, { ...base, sourceCode: "apple_music" }),
    expectedWithout,
    "an unregistered source must hash as if the map did not exist");

  const expectedWith = createHmac("sha256", key)
    .update(`written:record:v1\nu\nyoutube\nliked_video\nvid1\n` +
            `2026-08-14T00:00:00Z\n${canonicalize({ a: 1 })}\nprojector:2`)
    .digest("hex");
  assert.equal(
    recordFingerprint(key, { ...base, sourceCode: "youtube" }), expectedWith,
    "a registered source carries its projector version into the hash");
  assert.notEqual(expectedWith, expectedWithout);
});

test("the projector suffix separates, and never merges", () => {
  // A suffix can only split inputs that were equal. Two payloads that already
  // differed must still differ, which is the collision this hash fears most.
  const key = Buffer.from("k".repeat(32));
  const one = recordFingerprint(key, {
    userId: "u", sourceCode: "youtube", dataType: "liked_video",
    providerItemId: "vid1", occurredAt: null, payload: { title: "x" },
  });
  const two = recordFingerprint(key, {
    userId: "u", sourceCode: "youtube", dataType: "liked_video",
    providerItemId: "vid1", occurredAt: null, payload: { title: "x", playCount: 3 },
  });
  assert.notEqual(one, two);
  // And identical content still collides, which is what makes a re-distill of
  // unchanged rows cheap.
  const again = recordFingerprint(key, {
    userId: "u", sourceCode: "youtube", dataType: "liked_video",
    providerItemId: "vid1", occurredAt: null, payload: { title: "x" },
  });
  assert.equal(one, again);
});

test("content fingerprint ignores the projector, record fingerprint does not", () => {
  // The pair is what lets the server separate "your data changed" from "our
  // reading changed". Equal content plus differing record means a projection
  // bump and nothing else, which is the only case safe to supersede.
  const key = Buffer.from("k".repeat(32));
  const parts = {
    userId: "u", sourceCode: "youtube", dataType: "liked_video",
    providerItemId: "vid1", occurredAt: null, payload: { a: 1 },
  };
  assert.notEqual(recordFingerprint(key, parts), contentFingerprint(key, parts),
    "youtube is registered, so the two must differ");

  const music = { ...parts, sourceCode: "apple_music" };
  assert.equal(recordFingerprint(key, music), contentFingerprint(key, music),
    "an unregistered source has no projector, so the two coincide");

  // A real payload change moves both, which is what keeps history beside it.
  const changed = { ...parts, payload: { a: 2 } };
  assert.notEqual(contentFingerprint(key, parts), contentFingerprint(key, changed));
});

test("a record row carries both fingerprints", () => {
  const row = toRecordRow(
    { record_source_code: "youtube", data_type: "liked_video",
      provider_item_id: "vid1", action_type: "liked_video",
      occurred_at: "2026-08-14T00:00:00Z",
      typed_payload: { kind: "video", value: { title: "#anime", channelID: "UCx" } } },
    0, { userId: USER, hmacKey: KEY, dek: DEK }
  );
  assert.equal(typeof row.content_fingerprint, "string");
  // YouTube is a registered projector, so the pair must differ — that gap is
  // exactly what tells the server this was a re-projection.
  assert.notEqual(row.content_fingerprint, row.record_fingerprint);
});
