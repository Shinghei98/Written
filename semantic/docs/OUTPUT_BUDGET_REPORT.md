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

**These figures are not reproduced by the committed program on this machine, and
that is now a missing tokenizer rather than a missing capability.** Until
2026-08-18 the program was structurally bound to v1 — `schema_limits` read four
keys v2 does not have and `make_response` emitted `abstain` — so no committed
code could produce this column and it was published beside a v1 column that was
reproducible. The program measures whichever schema the compiled contract names,
which is now v2, and its fixtures are asserted schema-valid by
`test_output_budget_report.py`. Re-running it needs the pinned Qwen tokenizer,
which is not present here; the numbers below stand as the earlier measurement
until it is.

Removing `evidence_fields`, `lookup_queries` and `relation_hypotheses`:

| script | v1 @256 | v2 @256 | fits under v2 |
|---|---|---|---|
| latin | 2,366 | **914** | yes |
| han / hangul | 5,271 | **1,984** | yes |
| combining | 11,076 | 4,114 | no |
| emoji + ZWJ | 18,756 | 6,934 | no |
| rare kana | 14,566 | 5,394 | no |
| emoji | 21,546 | 7,954 | no |

Scaffolding floor **616 → 274**.

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
| `tokenizer_manifest_sha256` | **not constructed** |

**Nothing here may be promoted into `terms.xlsx`** until a deployed gateway
attests the same values and the semantic evaluation passes.

## Gate blockers

- no deployed gateway attesting model / tokenizer / contract;
- no overflow route tested;
- `tokenizer_manifest_sha256` not constructed;
- no measurement against actual deployed Qwen output.

## Standing decisions

- **Batch size stays 2.**
- **No 194-character cap.**
- The fixture is synthetic and built to the measured *shape*, never from the
  corpus: real titles would commit one person's library as plain text, which is
  what `ontology-terms.csv` is git-ignored for.
