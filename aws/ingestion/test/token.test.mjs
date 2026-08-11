// Verifying the caller.
//
// **This is the only thing standing between a stranger and somebody else's
// vault.** `sub` decides whose rows get written, so every one of these cases is
// a way that could go wrong quietly: a signature checked against the wrong key,
// a payload read before the signature is checked, an expired token, a token
// minted by a different Supabase project.
//
// Real ECDSA throughout — a generated P-256 key, a real JWKS document, real
// signatures. Nothing here is stubbed except the network fetch that serves the
// JWKS, because a fake verifier would only ever prove itself.

import { test, before } from "node:test";
import assert from "node:assert/strict";

const ISSUER = "https://example.supabase.co/auth/v1";
process.env.SUPABASE_ISSUER = ISSUER;
process.env.SUPABASE_JWKS_URL = "https://example.supabase.co/auth/v1/.well-known/jwks.json";
process.env.AWS_REGION = "us-east-1";

let verifyAccessToken;
let signingKey, otherKey, jwksBody;

const b64url = (buffer) =>
  Buffer.from(buffer).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function makeKey(kid) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  return { pair, jwk: { ...jwk, kid, alg: "ES256", use: "sig" } };
}

async function sign(key, claims, header = {}) {
  const head = b64url(JSON.stringify({ alg: "ES256", typ: "JWT", kid: key.jwk.kid, ...header }));
  const body = b64url(JSON.stringify(claims));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey,
    Buffer.from(`${head}.${body}`, "utf8")
  );
  return `${head}.${body}.${b64url(signature)}`;
}

const validClaims = (overrides = {}) => ({
  iss: ISSUER,
  sub: "11111111-1111-1111-1111-111111111111",
  aud: "authenticated",
  role: "authenticated",
  exp: Math.floor(Date.now() / 1000) + 3600,
  ...overrides,
});

before(async () => {
  signingKey = await makeKey("key-1");
  otherKey = await makeKey("key-1"); // same kid, different key — the impersonation case
  jwksBody = { keys: [signingKey.jwk] };
  globalThis.fetch = async () => new Response(JSON.stringify(jwksBody), {
    status: 200, headers: { "content-type": "application/json" },
  });
  ({ verifyAccessToken } = await import("../index.mjs"));
});

const rejects = async (token, note) => {
  await assert.rejects(() => verifyAccessToken(token), (error) => {
    assert.equal(error.status, 401, `${note}: expected a 401, got ${error.status}`);
    return true;
  }, note);
};

test("a real token from the real key yields its subject", async () => {
  assert.equal(
    await verifyAccessToken(await sign(signingKey, validClaims())),
    "11111111-1111-1111-1111-111111111111"
  );
});

test("a token signed by another key with the same kid is refused", async () => {
  // The impersonation case. Matching the `kid` is a lookup, not a proof.
  await rejects(await sign(otherKey, validClaims()), "foreign signature");
});

test("a payload edited after signing is refused", async () => {
  const token = await sign(signingKey, validClaims());
  const [head, , signature] = token.split(".");
  const forged = b64url(JSON.stringify(validClaims({ sub: "22222222-2222-2222-2222-222222222222" })));
  await rejects(`${head}.${forged}.${signature}`, "swapped subject");
});

test("an expired token is refused", async () => {
  await rejects(await sign(signingKey, validClaims({ exp: Math.floor(Date.now() / 1000) - 1 })), "expired");
});

test("a token from another Supabase project is refused", async () => {
  await rejects(await sign(signingKey, validClaims({ iss: "https://elsewhere.supabase.co/auth/v1" })), "wrong issuer");
});

test("an anon or service token is refused", async () => {
  // `authenticated` is the only role that names a person. An anon token has a
  // valid signature and no subject worth trusting.
  await rejects(await sign(signingKey, validClaims({ role: "anon" })), "anon role");
  await rejects(await sign(signingKey, validClaims({ aud: "", role: "service_role" })), "service role");
});

test("a token with no subject is refused", async () => {
  await rejects(await sign(signingKey, validClaims({ sub: "" })), "empty subject");
});

test("alg is not taken from the token", async () => {
  // The classic JWS attack: claim an algorithm the verifier will accept on
  // terms the attacker controls. Only ES256 is ever honoured.
  const claims = validClaims();
  const head = b64url(JSON.stringify({ alg: "none", typ: "JWT", kid: "key-1" }));
  const body = b64url(JSON.stringify(claims));
  await rejects(`${head}.${body}.`, "alg none");
  await rejects(await sign(signingKey, claims, { alg: "HS256" }), "alg HS256");
});

test("a malformed token is refused rather than throwing something else", async () => {
  // The last three have the right *arity* and unreadable segments — the case
  // the deployed endpoint answered with a 500 until it was fixed, because a
  // bare SyntaxError carries no status and falls past every 401 branch.
  for (const token of ["", "a.b", "a.b.c.d", "...", "not-a-token",
                       "not.a.token", "eyJhbGciOiJFUzI1NiJ9.%%%.sig", "[].[].x"]) {
    await rejects(token, `malformed: ${JSON.stringify(token)}`);
  }
});

test("an unknown kid refetches the JWKS exactly once", async () => {
  // A rotation must not be a total outage, and a malformed token must not be a
  // denial-of-service against the JWKS endpoint.
  let fetches = 0;
  globalThis.fetch = async () => {
    fetches += 1;
    return new Response(JSON.stringify(jwksBody), { status: 200 });
  };
  const rotated = await makeKey("key-2");
  await rejects(await sign(rotated, validClaims()), "unknown kid");
  assert.equal(fetches, 1, "should refetch once, and only once, per verification");
});

test("a rotated key is picked up without a redeploy", async () => {
  const rotated = await makeKey("key-3");
  jwksBody = { keys: [signingKey.jwk, rotated.jwk] };
  assert.equal(
    await verifyAccessToken(await sign(rotated, validClaims())),
    "11111111-1111-1111-1111-111111111111"
  );
});
