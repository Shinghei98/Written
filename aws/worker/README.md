# The semantic worker

Drains `semantic_private.worker_jobs`, decrypts vault rows and writes
`observations`. Runs as a Lambda; `run_once` claims at most one job per
invocation, so the schedule is the loop.

**It is the vendored package, not a reimplementation.** `SemanticWorker` and
`PostgresJobQueue` come from `written_ontology` — the contract's own
implementation, with its own tests: `FOR UPDATE SKIP LOCKED`, lease tokens,
attempt limits, payload validation against the job contracts, and a fail-closed
default where an unhandled job type is marked *dead* rather than succeeded.
Writing a second queue in another language would have meant the thing running in
production was not the thing the tests cover. This directory adds only what a
Lambda needs and the package deliberately lacks: where the database is, and a
handler.

## The other half of the split

| | ingestion | worker |
|---|---|---|
| KMS | `GenerateDataKey`, `Encrypt`, `GenerateMac` | **`Decrypt`**, `GenerateMac`, `VerifyMac` |
| Postgres | one function, **zero** tables | 10 tables read, 2 written |
| Reads the vault back | **no** | yes |

Neither identity alone can both put data in the vault and take it out. That is
what makes the vault worth having, and both halves are verified by simulation
and by connecting rather than by reading policy JSON.

`semantic_worker` holds `bypassrls` and is narrowed by an **enumerated grant
list** instead of policies: RLS here is keyed on `auth.uid()`, which a batch
processor with no JWT can never satisfy, so a policy for this role could only be
`using (true)` — a second mechanism that decides nothing while the table grants
still decide everything. `0057` asserts the exact read and write sets by reading
the catalog, and that it reaches nothing outside `semantic_private`.

## What it will not do

**Music only.** Calendar and HealthKit rows are captured, encrypted, and left
unprojected. `private_observation_projection_is_valid_v03` returns `true`
immediately for every other source but imposes a strict sanitised shape on those
two — `calendar-v03`, `sanitized_classification`, `action_weight = 0`, a payload
under 1 KB carrying a `classification_state`. That shape is the *output of a
classifier* this file does not implement, and §7 is explicit that only the
current Calendar classifier may run over Calendar rows. Writing something that
merely satisfies the constraint would be inventing evidence.

**No scoring, resolution or embedding.** `recompute_user`'s payload carries four
model ids; only the user is used. A result stamped with a model that did not run
is worse than no result.

## Two things that bit, both packaging

**`typing_extensions` is named explicitly in `build.sh`.** psycopg 3 needs it on
Python before 3.13 and pip's resolver dropped it under `--platform`. The failure
was the package's own `install the postgres extra` message, which swallows the
real `ImportError` and points at entirely the wrong thing. `build.sh` now checks
the staged tree for every expected module, so a missing one fails at build.

**Wheels for the Lambda, not for this laptop.** `--platform
manylinux2014_x86_64 --only-binary :all:` — without it pip resolves arm64 wheels
on an Apple machine and the Lambda fails at *import* with a missing `.so`, which
reads like a typo rather than an architecture mismatch. `boto3` is deliberately
absent: the runtime bundles it, and shipping a copy pins a version that drifts
from the one AWS patches.

## The seam is in the wrong place, and the schema said so

**`recompute_user` cannot create observations, and the design has to move.**
`observations` carries a trigger — `guard_observation_ingestion_run` — whose
second line is:

    if not found or run_row.status <> 'running' then
      raise exception 'observations may only be appended to their running ingestion run';

`finalize_ingestion_run_v031` enqueues `recompute_user` **after** the run
closes, so by the time this worker claims the job the run is `succeeded` and
every insert is refused. No grant fixes that; it is the schema stating where
classification belongs.

It belongs in **ingestion**, which already holds the plaintext before it
encrypts it and runs while the run is open. `ingestion_run_items` carrying both
`raw_source_record_id` and `observation_id`, with a check requiring at least
one, says the same thing from the other side.

So this directory keeps its identity, its packaging and its decrypt path — all
of which are proven — and the projection moves to `aws/ingestion`. What
`recompute_user` should do instead is what its name says: resolve existing
observations to concepts, score and embed. That is the next piece.

## Working on it

    ./build.sh          # dist/worker.zip, linux x86_64 wheels, ~11 MB
    aws lambda update-function-code --function-name written-semantic-worker \
      --zip-file fileb://dist/worker.zip
    aws lambda invoke --function-name written-semantic-worker \
      --payload '{}' --cli-binary-format raw-in-base64-out /tmp/w.json

The connection comes from Secrets Manager (`written/semantic-worker`) and is
verified against the pinned `supabase-ca.pem` — the pooler's chain is
self-signed, so `verify-full` against the system store fails, which is exactly
the failure that gets "fixed" by turning verification off.

`(EAUTHQUERY) user not found in the database` from Supavisor means the role has
no password yet — it is created `nologin` by `0057`, because a secret in a
migration is a secret in git. The password is generated and stored without ever
being printed; only a SCRAM verifier is pasted into the SQL editor.
