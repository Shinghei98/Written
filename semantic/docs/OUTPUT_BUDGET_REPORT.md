# Candidate tokenizer exploration — **not an `output_budget` gate pass**

**Measured 2026-08-17, repaired 2026-08-18.** Reproduce with:

    ./semantic/.venv/bin/python tools/output_budget_report.py \
      --tokenizer <tokenizer.json> --model-revision <sha>

The program **always exits non-zero**. It produces evidence toward the
`output_budget` gate and cannot pass it: that needs a deployed gateway attesting
the same model, tokenizer and contract, plus a tested overflow route. Neither
exists.

## The first version of this report was wrong

Kept here rather than deleted, because the corrections are the findings.

- **The fixture was invalid against the schema it claimed to measure.**
  `evidence_fields` carried `primary_performer`, `album`, `genres` where the enum
  permits only `title`, `channel_label`, `description_excerpt`, `tags`;
  `item_index` ran to 399 against a maximum of 3; `lookup_queries` were measured
  at 64 characters where 128 is legal. **It measured a response the model could
  not legally emit — and it understated the cost**, because the legal response is
  larger.
- **Nothing was validated.** No generated response was ever checked.
- **The singleton ceiling was wrong.** 2986.67 formatted with `%.0f` gives
  `2987`, and `512 + ceil(1.2 × 2987) = 4097`. Every "safe" length was derived
  against a ceiling one token too generous. **It is 2,986.**
- **`sha256(tokenizer.json)` was called a tokenizer manifest.** A manifest covers
  tokenizer, chat template, serving engine, schema, prompt, grammar and compiled
  contract, canonically serialised and hashed together. The field now reports
  `null` with a note.
- **It exited 0 whenever the synthetic q99 fitted**, even when its own
  schema-maximum probe failed.
- **It recommended a 194-character cap that does not work.** Reverted.

## A character cap cannot bound token cost

At `maxLength: 256`, tokens per item under **v1** — schema-valid fixture, five
mentions, singleton ceiling **2,986**, scaffolding floor **616**:

| script | tokens | fits alone |
|---|---|---|
| emoji | **21,546** (9.1× latin) | no |
| emoji + ZWJ | 18,756 | no |
| rare kana | 14,566 | no |
| combining marks | 11,076 | no |
| han / hangul / common kana / arabic | 5,271 | no |
| devanagari | 4,796 | no |
| cyrillic | 2,956 | yes |
| JSON-hostile (quotes, backslashes) | 2,651 | yes |
| latin | 2,366 | yes |
| thai | 1,631 | yes |

**Nine of thirteen scripts cannot produce a legal single-item response.**
Tokens per character varies about tenfold, so no `maxLength` bounds tokens: a cap
low enough for ZWJ emoji is useless for Latin. **The bound belongs where tokens
are known — the gateway.**

The earlier claim that CJK costs only 5% more came from a fixture whose content
was a small share of an inflated envelope. Against a length-matched comparison at
schema maximum, Han and Hangul cost **2.2× Latin**, and the tail is far worse.

## What the v2 shape costs

**Measured 2026-08-18 by the committed program, against the pinned tokenizer.**
Reproduce with the command at the top of this file. Every figure below comes out
of `tools/output_budget_report.py` reading whichever schema the compiled contract
names, and its fixtures are asserted schema-valid by
`semantic/tests/test_output_budget_report.py`.

| script | v1 @256 | v2 @256 | fits under v2 |
|---|---|---|---|
| latin | 2,366 | **921** | yes |
| cyrillic | — | **1,141** | yes |
| thai | — | **651** | yes |
| devanagari | — | **1,821** | yes |
| han / hangul / arabic / common kana | 5,271 | **1,991** | yes |
| json-hostile | — | **1,041** | yes |
| combining | 11,076 | 4,121 | no |
| rare kana | 14,566 | 5,401 | no |
| emoji + ZWJ | 18,756 | 6,941 | no |
| emoji | 21,546 | 7,961 | no |

Scaffolding floor **616 → 281**. Singleton ceiling **2,986**, which is where
`512 + ceil(1.2 x)` reaches exactly 4,096; at 2,987 it is 4,097.

### The previously published v2 column was seven tokens low, and why

This file used to state 914 / 1,984 / 4,114 / 5,394 / 6,934 / 7,954 and a floor
of 274. **The tokenizer is not the difference** — the `tokenizer.json` sha256
recorded below is the one those numbers were taken with, and it is the one just
measured. Every figure moved by exactly **+7**, uniformly across every script and
the floor, which places the difference in the item envelope rather than in
content.

Measured directly: a v2 item carrying `status` and `abstain_reason` is 281
tokens; the same item with `abstain: false` and no `abstain_reason` is 275, and
with neither key 269. The published 274 sits among those and matches none of
them exactly, so the fixture behind it cannot be reconstructed — **which is the
finding.** It was produced by code that is not in the repository, and the shape
it implies is one `mention_extract_v2` refuses twice over: `abstain` is not a
property it declares and `additionalProperties` is false, while `abstain_reason`
is required. A report measuring a response the model could not legally emit is
the first version of this program's defect, arriving one schema version later
through a different door.

**v2 fixes the realistic scripts and does not close the overflow route.** Han and
Hangul go from overflowing to comfortable, which is the workload the corpus
actually has — 30.8% of titles and 33.1% of albums carry CJK. Emoji, rare kana
and combining marks still overflow at 256. **No field-set change removes that;
only a lower `maxLength` or a tested overflow route does**, which makes the
overflow route a requirement rather than a nicety.

## Corpus shape, measured live

`semantic_private.observations`, 2026-08-17:

| field | n | with CJK | p99 chars | max chars | p99 CJK | max CJK |
|---|---|---|---|---|---|---|
| `title` | 3,094 | **30.8%** | 111 | 164 | 15 | 39 |
| `album` | 2,586 | **33.1%** | 65 | 112 | 17 | 25 |
| `primary_performer` | 3,001 | 13.1% | 103 | 166 | 6 | 10 |

`observation_mentions` shows 4% CJK and is misleading: mentions are
already-extracted and frequently romanised. **The model reads the payload.**

The corpus does not reach `maxLength` today — longest title 164 characters,
longest CJK run 39 — so the overflow is **latent**, and arrives with one unusual
row rather than gradually.

## Candidate identity — not a production pin

| | |
|---|---|
| `llm.model.default` | `Qwen/Qwen3.5-9B` |
| revision measured | `c202236235762e1c871ad0ccb60c8ee5ba337b9a` |
| `tokenizer.json` sha256 | `5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42` |
| output schema | `mention_extract_v2.schema.json` |
| schema sha256 | `0cdf52b572f7d89d72447c5bc2e5aa67aaec3047cbfbcbf10dcb0df7fdc5de38` |
| compiled contract sha256 | `5abbc404bd1212ba5cf04a171c79332976269bf61f22d422e9c56f0912fd29fc` |
| `tokenizer_manifest_sha256` | **not constructed** |

**These are identities, not an attestation.** They say which files produced the
numbers above; nothing here proves a gateway loaded any of them. The tokenizer
was fetched by file at the pinned revision — tokenizer artifacts only, no
weights — so it is a candidate measurement in the sense the status field already
claims. **Stage 3 regenerates the manifest and reruns this measurement from what
the gateway actually loaded, and if the deployed hashes differ these numbers are
discarded rather than reconciled.**

**Nothing here may be promoted into `terms.xlsx`** until a deployed gateway
attests the same values and the semantic evaluation passes.

## Gate blockers

- no deployed gateway attesting model / tokenizer / contract;
- no overflow route tested;
- `tokenizer_manifest_sha256` not constructed;
- no measurement against actual deployed Qwen output.

## Standing decisions

- **The wire maximum is 2 and the evaluation batch is 1.** This said "batch size
  stays 2", which was true of the contract when it was written and is not now:
  `mention_extract_v2` sets `items.maxItems` to 2 so a third cannot be emitted by
  a model that misread its instructions, while the calibrated and default batch
  are both 1. The first deployed evaluation is singleton-only, and two-item
  packing waits on a real singleton distribution and a forced-overflow test —
  a q99 deliberately leaves a tail, and the overflow route is what makes the tail
  safe rather than the packing formula.
- **No 194-character cap.**
- The fixture is synthetic and built to the measured *shape*, never from the
  corpus: real titles would commit one person's library as plain text, which is
  what `ontology-terms.csv` is git-ignored for.
