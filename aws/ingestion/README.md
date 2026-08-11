# The ingestion endpoint

§4's "authenticated ingestion service". It takes a batch of `SourceEnvelope`s
from a signed-in device, encrypts each payload under a data key only KMS can
unwrap, and hands the ciphertext and the wrapped key to Postgres in one call.

**Live, and nothing sends to it yet.** No Swift code calls this; Phase 1 is
dual-write and this is the half that did not exist.

    POST https://c2u0avzqti.execute-api.us-east-1.amazonaws.com/v1/ingest
    Authorization: Bearer <supabase access token>

## What it cannot do, which is the design

| | |
|---|---|
| AWS identity | `written-semantic-ingestion` — `GenerateDataKey`, `Encrypt`, `GenerateMac`. **No `Decrypt`.** |
| Postgres identity | `semantic_ingestor` — execute on **one** function, **zero** table privileges |

So the thing exposed to the internet can write into the vault and cannot read a
single row back, including the rows it wrote a moment ago. Both halves are
verified by simulation and by connecting rather than by reading policy JSON —
see `supabase/DEPLOY.md`.

**No shared secret with Supabase.** The caller's token is verified against the
project's published JWKS, so the user id arrives as a signature over a public
key. That is what made hosting here viable at all.

## Four things that are easy to get wrong

- **The consent purpose is derived, never taken from the caller.** A client that
  chooses its own could file HealthKit under `source_distillation` and step
  around the grant the v0.3.1 contract wants that transfer gated on.
- **The fingerprint is computed over a canonical form.** It drives idempotency
  through a partial unique index, so if the same content can serialise two ways
  a retry writes a second row and every count downstream doubles.
- **`source_item_hmac` is salted with the user id.** Without it, two accounts
  with the same song hash identically, and anybody holding the database learns
  who shares a library with whom — from the column that exists to avoid holding
  anything identifying.
- **The data key is per call.** Forced, not chosen: this identity has no
  `Decrypt`, so it cannot recover a key it stored earlier, and a Lambda holds
  nothing between invocations. `0053` is the database half of the same fact.

## Two measurements worth keeping

**The pooler's certificate is self-signed.** Plain `rejectUnauthorized: true`
fails with `SELF_SIGNED_CERT_IN_CHAIN` — which is the failure that gets "fixed"
by setting it to `false`, leaving a connection carrying somebody's whole library
encrypted but unauthenticated. `supabase-ca.pem` (Supabase Root 2021 CA, SHA-256
`807025AD…6CAFA`) is pinned instead, which moves the failure to `28P01 password
authentication failed` — the handshake verifying. **It expires 2031-04-26.**

**The Node 22 runtime really does bundle AWS SDK v3.** That was an assumption
until the first deployed invocation returned a clean 401 rather than a module
error, which is why `--omit=dev` in `build.sh` is not an optimisation: shipping
the SDK would pin a version that then drifts from the one AWS patches.

## Working on it

    npm install
    npm test          # 23 tests, no AWS and no network
    ./build.sh        # dist/ingestion.zip, production deps only
    aws lambda update-function-code --function-name written-semantic-ingestion \
      --zip-file fileb://dist/ingestion.zip

The tests cover the two places a mistake would be invisible: the pure transforms
(canonical form, fingerprint stability, IV reuse, purpose derivation) and token
verification, with real ECDSA — a generated P-256 key, a real JWKS, real
signatures, including a token signed by a *different* key carrying the *same*
`kid`.

**A live probe found what the tests did not.** `not.a.token` has three parts, so
it passed the arity check and died in `JSON.parse` with a bare `SyntaxError`
that carried no status and fell through to a 500. The unit cases all had the
wrong number of parts. Both are covered now.

## If tokens start failing with 401

Check `SUPABASE_ISSUER` first. It is set to
`https://fwnezkbesjoazlpaflbq.supabase.co/auth/v1`, which is GoTrue's
`API_EXTERNAL_URL` plus `/auth/v1` — correct for a hosted project and the one
environment variable here that has never been checked against a real token.
CloudWatch says `wrong issuer` when it is the cause; the caller only ever sees
`unauthorized`, deliberately.
