# The tokenizer / CJK output-budget report

**Measured 2026-08-17.** Reproduce with:

    ./semantic/.venv/bin/python tools/output_budget_report.py --tokenizer <tokenizer.json>

This is the measurement the `output_budget` deployment gate waits on. The
contract records it as `blocked_until_pinned_tokenizer_kpop_cjk_report_passes`
and leaves `tokenizer_manifest_sha256` as
`required_from_pinned_deployment_not_yet_measured`.

## What is pinned, and what is not

| field | value |
|---|---|
| `llm.model.default` | `Qwen/Qwen3.5-9B` |
| model revision measured | `c202236235762e1c871ad0ccb60c8ee5ba337b9a` |
| `tokenizer.json` sha256 | `5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42` |
| `tokenizer_config.json` sha256 | `316230d6a809701f4db5ea8f8fc862bc3a6f3229c937c174e674ff3ca0a64ac8` |
| `config.json` sha256 | `d0883072e01861ed0b2d47be3c16c36a8e81c224c7ffaa310c6558fb3f932b05` |

**This pins what was measured, not what is deployed.** `llm.gateway.revision`
remains unpinned because there is no gateway: the config specifies one — `POST
/v1/semantic/extract`, provider-neutral OpenAI-compatible, `enable_thinking=false`,
strict `json_schema` — and nothing implements it. `model_invocations` is 0.
**A deployment that loads a different revision invalidates every number below
and must re-run this report.**

## The corpus, measured live

`semantic_private.observations`, 2026-08-17:

| field | n | with CJK | p99 chars | max chars | p99 CJK | max CJK |
|---|---|---|---|---|---|---|
| `title` | 3,094 | **30.8%** | 111 | 164 | 15 | 39 |
| `album` | 2,586 | **33.1%** | 65 | 112 | 17 | 25 |
| `primary_performer` | 3,001 | 13.1% | 103 | 166 | 6 | 10 |

`observation_mentions` shows only 4% CJK, which is misleading and worth naming:
mentions are already-extracted creator and work fields and are frequently
romanised. **The model reads the payload, not the mentions**, so the payload is
the distribution that matters.

## The fixture is synthetic on purpose

`kpop_cjk_output_stress` is built to the measured *shape* and not from the
corpus. A fixture made of real titles would commit one person's library to the
repository as plain text — exactly what `ontology-terms.csv` is git-ignored for.
Seeded, so the report reproduces.

## Results

400 items, 5 mentions each (the schema maximum), compact JSON:

| | tokens |
|---|---|
| scaffolding floor (1-char fields) | **581** |
| p50 item | 772 |
| **q99 item** | **972** |
| max item in fixture | 1,198 |
| schema-maximum item (256-char CJK fields) | **4,396** |

| | mean tokens |
|---|---|
| CJK-bearing items | 804.5 |
| Latin items | 764.9 |
| **CJK penalty ratio** | **1.052** |

### Finding 1 — the reserve holds, and the gate's premise is wrong

`uncalibrated_item_reserve_tokens = 1280` **covers the q99 of 972** with 24%
headroom. The gate exists because CJK was expected to inflate output badly.
**It does not: the penalty is 5%.** Qwen3.5's vocabulary covers Han and Hangul
well, and — more importantly — **the item is 59% JSON scaffolding before any
content exists.** Five mentions × twelve required fields dominates; the title's
script barely moves the total.

At q99, **3 items fit** a request. The contract's `calibrated_max_items = 2` is
therefore conservative rather than wrong, and could be raised on this evidence.

### Finding 2 — a schema-legal item can be unproducible

The packing formula gives a per-item ceiling of **2,987 tokens** for a batch of
one. A single item whose fields are at the schema's `maxLength: 256` **in CJK
costs 4,396** — it exceeds the entire 4,096-token output budget by itself.
The model cannot emit a legal response; it hits `finish_reason: length`, which
the gateway contract refuses outright, so the failure is total rather than
degraded.

**The cliff is script-dependent:**

| script | max safe field length | cost at 256 chars |
|---|---|---|
| Latin | **256** (no cliff) | 1,316 |
| Han | **194** | 3,596 |
| Hangul | **194** | 3,596 |

The corpus does not reach this today — the longest observed title is 164
characters and the longest CJK run is 39. **So this is a latent failure, not a
live one**, and it is the kind that arrives with one unusual row rather than
gradually.

## What follows

1. **The reserve needs no change.** 1,280 is safe for observed data and the CJK
   fear is unfounded for this tokenizer.
2. **Cap the surface fields at 194 characters**, in the schema rather than in a
   prompt — `surface`, `canonical_label_hypothesis` and
   `object_label_hypothesis` are all `maxLength: 256` and all three feed the
   overrun. A cap the schema enforces cannot be forgotten by a caller; an
   instruction in a prompt can.
3. **Re-run this against the deployed revision** before the gate is called
   passed. The numbers are only true of
   `c202236235762e1c871ad0ccb60c8ee5ba337b9a`.

## What this report does not establish

- That a gateway exists or serves this revision. It does not.
- That the model's *actual* outputs resemble the worst-case envelope. This
  measures the largest legal response, which is what a reserve must cover, not
  what a typical response costs.
- Input-side budget. The gate and this report are about output.
