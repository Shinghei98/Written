# Contract tests for the semantic migrations

Adapted from `Written-Semantic-System-v0.3.1`'s `sql/tests/`. They are the only
executable proof that `0042`–`0047` do what the contract says; the commits that
landed those migrations verified them by grants fingerprint and replay, not by
running these.

## The numbering, which is the easiest thing here to get wrong

The reference chain numbers its migrations `001`–`006`. This repository's are
`0042`–`0047`, so **contract numbering is off by two** — and the two
fixture-backed lanes are off by *one* on top of that, because each fixture is
loaded before the migration it tests.

Every file here is therefore named for **the app migration it gates**, not for
the reference file it came from:

| This file | Adapted from | Gates |
|---|---|---|
| `0044_version_rollover.sql` | `001_version_rollover.sql` | `0042`–`0044` |
| `0044_integrity_contract.sql` | `002_integrity_contract.sql` | `0042`–`0044` |
| `0044_exact_revision_finalization.sql` | `003_exact_revision_finalization.sql` | `0042`–`0044` |
| `0045_product_surfaces_contract.sql` | `004_product_surfaces_contract.sql` | `0045` |
| `0046_private_ingestion_and_fitness_contract.sql` | `005_private_ingestion_and_fitness_contract.sql` | `0046` |
| `0046_calendar_upgrade_contract.sql` | `005_calendar_upgrade_contract.sql` | `0046` |
| `0047_current_state_and_surface_hardening_contract.sql` | `006_current_state_and_surface_hardening_contract.sql` | `0047` |
| `0047_surface_fact_upgrade_contract.sql` | `006_surface_fact_upgrade_contract.sql` | `0047` |
| `fixtures/0046_calendar_upgrade_fixture.sql` | `fixtures/**004**_calendar_upgrade_fixture.sql` | `0046` |
| `fixtures/0047_surface_fact_upgrade_fixture.sql` | `fixtures/**005**_surface_fact_upgrade_fixture.sql` | `0047` |

Note the last two rows: the reference fixture called `004` gates the app's
`0046`, and the one called `005` gates `0047`.

## Run order

Straight lane — apply, replay, contract:

```
0001 … 0041           replay from files, or restore a scrubbed clone
0042, 0043, 0044   →  0044_version_rollover
                      0044_integrity_contract
                      0044_exact_revision_finalization
0045 ; replay 0045 →  0045_product_surfaces_contract
0046 ; replay 0046 →  0046_private_ingestion_and_fitness_contract
0047 ; replay 0047 →  0047_current_state_and_surface_hardening_contract
```

Fixture-backed upgrade lanes, which prove the migrations upgrade *populated*
state rather than only an empty schema — run each on its own database, because
they are stateful and mixing them makes the result unreadable:

```
lane A   0042–0045, load fixtures/0046_calendar_upgrade_fixture.sql,
         apply 0046, replay 0046, run 0046_calendar_upgrade_contract.sql

lane B   0042–0046, load fixtures/0047_surface_fact_upgrade_fixture.sql,
         apply 0047, replay 0047, run 0047_surface_fact_upgrade_contract.sql
```

## What was changed from the reference, and what deliberately was not

Two mechanical substitutions, 766 in all: **725** `private.` → `semantic_private.`
and **41** bare `'private'` schema arguments. The reference chain names its own
schema `private`; this application already owns a `private` schema holding
`push_config` (the shared push secret), `notify` and `collaborators`, and the
contract is explicit that semantic installation must never touch it.

**Privacy-class *values* were left alone** — `'private_text'`,
`'private_calendar_sanitized'`, `'private_fitness_sanitized'`,
`'private_health_raw'`. They are check-constraint values, not schema names, and
rewriting them is how a mechanical rename corrupts a contract while still
passing. Counts were compared against the reference before and after: 5 / 5 / 1
/ 5, unchanged.

Verified after adaptation: no file names any real `private` object, no bare
`private.` schema reference survives, nothing was double-substituted into
`semantic_semantic_private`, and every file differs from its reference by
exactly the 15-line header — so the substitution touched no structure.

## Not covered here

`006`'s own header requires something these files cannot do: the finalizer and
the exposure/revocation races must be run **from two independent sessions at
READ COMMITTED** on native PostgreSQL. Nothing calls those functions yet, so it
is Phase 5 work — but it is a release gate, not an optional extra.
`tools/chat_e2e.py` is the pattern to extend, since it already plays a second
person over REST for exactly this reason.
