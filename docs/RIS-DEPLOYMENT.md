# Running the pipeline on RIS

**RIS is where the pipeline is measured.** This file is how to run it: access,
the workflow, the scopes, and what each failure looks like. The *rules* — what
may never travel, what the lane may not waive — are in `CLAUDE.md`; the grammar
and the golden set are in `docs/GRAMMARBOOK.md`.

**Everything here runs without AWS.** That is not a workaround; it is the
design. The lane reads `public.distilled_records`, which is plaintext at rest
and *more* complete than the promoted projection — it keeps the calendar titles
and YouTube titles the projection strips. Proven end to end on 2026-08-24 with
the AWS account suspended.

---

## 1. What is bypassed here, and what is not

| | AWS lane | RIS lane |
|---|---|---|
| Reads | the vault, through KMS | `summary_distilled_records`, plaintext |
| Filed evidence | encrypted under the account's data key | plaintext under `ris_lab_plaintext_v1` |
| `source_item_hmac` | keyed via KMS `GenerateMac` | content matching, refusing ambiguity |
| Calendar mentions | refused unless publicly eligible | a second door, keyed on `logical_extraction_key like 'ris|%'` |
| **30-day retention** | enforced | **still enforced** |
| **Third-party terms** | binding | **still binding** |

**The key discipline is bypassed; the retention clock is not.** III.E.4's clock
is a third party's term, not the vault's convenience — *"that is the line between
what the owner authorised and what nobody can."*

---

## 2. Access

**LSF, not Slurm.** No `sbatch`, no partitions, no modules, no venv. Everything
runs inside a Docker image LSF launches.

    ssh compute1            # Duo answered interactively; keep the master open

| | |
|---|---|
| Queue | `-q general` |
| User group | `-G compute-gfwu` — **an LSF group, not the storage name** |
| CPUs / memory | `-n 8 -M 64GB -R "rusage[mem=64GB]"` |
| GPU | `-gpu "num=1:gmodel=NVIDIAA100_SXM4_80GB" -R "gpuhost"` |
| Image | `-a "docker(vllm/vllm-openai:v0.27.1)"` — **pinned, see §7** |
| Entrypoint | `LSF_DOCKER_ENTRYPOINT=/bin/bash` |
| Volume | `LSF_DOCKER_VOLUMES="/storage2/fs1/erichuang/Active:/storage2/fs1/erichuang/Active"` |
| `$ROOT` | `/storage2/fs1/erichuang/Active/Users/David/written` |
| Weights | `$ROOT/models/qwen3.5-9b` — 19 GB |

`bhist` is disabled here, so `bjobs -a` is the only job history, and it purges
quickly. **Credentials never leave the Mac** — every database read shells out to
`supabase db query --linked`; the GPU sees titles and nothing else.

**Storage not mounted?** Walk the path one level at a time, because `scp`
reports only the leaf:

    ssh compute1 'for p in /storage2 /storage2/fs1 /storage2/fs1/erichuang \
        /storage2/fs1/erichuang/Active /storage2/fs1/erichuang/Active/Users/David/written; do
      [ -d "$p" ] && echo "OK   $p" || { echo "GONE $p"; break; }; done'

A missing **allocation** is a lease or a rename; a missing **leaf** is a cleaned
work tree, which takes the 19 GB of weights with it; **mounted but unlistable**
is a credential problem. Only the middle is recoverable without RIS.

---

## 3. The workflow, in order

### Build the work list (Mac)

    python3 tools/ris_build_items.py out/ris/items_v16.jsonl [--limit N]

Reads `summary_distilled_records` plus the top-40 `broader` parents as
`parent_candidates`. Applies the source exclusions, the calendar gate, the
150-subscriber floor, and `fields_for` — which routes per source, because
`creator` and `detail` mean four different things across sources.

### Shard it

`run_extract.sh` reads `$ROOT/work/v16_shard_$SHARD.jsonl`, one file per shard.
Four shards, one A100 each. **Nothing in the repository splits the file** — do it
by hand and check the line counts sum to the item count.

### Stage

**The output schema is named by the contract, never by this file.**
`ris_extract.py:34` reads `versions.output_schema` and loads that filename from
beside itself, so the schema staged has to be the one the contract asks for.
This block named `mention_extract_v4.schema.json` while the contract had already
moved to v5 — **the job dies on a missing file after the stage, at the point
where a GPU has been allocated**, and the version gate cannot catch it: that
gate checks the prompt version and this is a different field. Derive it.

    SCHEMA=$(python3 -c "import json;print(json.load(open('semantic/contracts/compiled_semantic_contract_v1.json'))['versions']['output_schema'].rsplit('/',1)[-1])")

    scp tools/ris_extract.py aws/serving/serve.py \
        semantic/contracts/compiled_semantic_contract_v1.json \
        "semantic/contracts/$SCHEMA" \
        tools/ris/run_extract.sh tools/ris/submit_extract.sh \
        out/ris/v16_shard_0*.jsonl \
        compute1:$ROOT/work/

`serve.py` is the production prompt builder — **the run is only meaningful
because it is not a reimplementation**. The contract carries the prompt version,
so **staging a stale one produces a v14 corpus that reads as a v16 result**;
`run_extract.sh` refuses to start if the contract on the cluster disagrees with
the job.

**`v16_shard_<n>.jsonl` is a filename convention, not a claim about the prompt.**
It is shared with `submit_extract.sh` and `run_extract.sh`, both of which open
that exact name; the corpus inside it is whichever one was just built.

### Submit

    ssh compute1 'bash $ROOT/work/submit_extract.sh'          # all four
    ssh compute1 'bash $ROOT/work/submit_extract.sh 02'       # one

**Use the script, not a hand-written `bsub`.** See §7 for the two defects in the
form that used to be documented here.

### Watch

    ssh compute1 'bjobs -w; tail -40 $ROOT/work/extract_v16_00.log'

The first line is the contract's prompt version, printed **before the GPU is
touched**, so a stale stage costs a second rather than an hour. Expect ~10
minutes per shard, nearly all of it model load.

### Collect and validate (Mac)

    scp 'compute1:$ROOT/out/v16_results_0*.jsonl' out/ris/
    PYTHONPATH=semantic/src semantic/.venv/bin/python tools/ris_ingest_results.py \
        out/ris/items_v16.jsonl out/ris/v16_results_0*.jsonl out/ris/verdicts_v16.json

**Validation happens here, not on the cluster.** The contract, the schema and the
semantic validator live with the repository; the GPU emits raw text and this
machine decides what survives. Order is fixed: overflow check → JSON parse →
JSON-Schema → **`repair_offsets`** → `validate_response`.

### Emit and apply

    python3 tools/ris_link_observations.py out/ris/links.json
    python3 tools/ris_emit_dictionary.py out/ris/verdicts_v16.json <n>
    python3 tools/ris_emit_mentions.py   out/ris/verdicts_v16.json links.json items.jsonl <n>
    supabase db push && ./tools/replay_contracts.sh

Each emitter **writes a migration and applies nothing**.

### Score it, from the laptop

    WRITTEN_DATABASE_URL=... python3 tools/run_worker_stages.py --user <uuid>

*"Everything between a mention and a card is SQL, and none of it needs AWS."*
Runs `recompute_user → resolve_mention → build_candidate_overlay →
aggregate_term_candidates → build_review_items → process_mint_requests`, in that
order, because **the order is the contract**. Refuses `extract_mentions` (the RIS
toolchain substitutes for it) and `build_fitness_snapshot` (needs KMS `Decrypt`).
Run per account, serially.

---

## 4. Measuring accuracy: two different runs

**The production corpus cannot be scored against the fixtures.**
`score_categorisation.py` matches items to cases by `row_id` carrying the case
id; production rows carry content hashes, so every case reports
`absent_from_answer` and `scored: 0`. **That is the scorer being right** — *"a
missing run and a run that failed every case are different facts."*

To get a number, run the fixtures as their own shard:

1. Build items from `evaluation_corpus_v2.json` with `row_id = case id`, on the
   same item shape as production (`out/ris/items_fixtures_v16.jsonl`).
2. Stage as `v16_shard_fx.jsonl`, submit with `submit_extract.sh fx`.
3. Ingest to `verdicts_fixtures_v16.json`, then
   `python3 tools/score_categorisation.py <that file>`.

**Real titles never become fixtures.** `out/` is git-ignored and migrations
`0239`/`0240` refuse an evaluation invocation naming a user, an observation or
retained source text — *"a gold set of real titles would be somebody's viewing
history in git history."* A hand-labelled row becomes a case by carrying the
**lesson** across and inventing the title.

---

## 5. The relabel pass

For terms whose own language differs from the script they were written in.

    python3 tools/ris_relabel_build.py verdicts.json relabel.jsonl items.jsonl
    # stage, then: bash $ROOT/work/run_relabel.sh
    python3 tools/ris_relabel_merge.py verdicts.json relabel_out.jsonl merged.json

**A repair may improve a label and may never damage one.** The merge replaces a
native only when the current one echoes the surface, and an English label only on
a **widening** (`Luffy` → `Monkey D. Luffy`; never `Kim Chaewon` → `Chae Won`).
Everything else is counted and discarded — *"a pass that improved nothing must
report zero rather than looking like it ran."*

---

## 6. Scopes and config

Every environment variable in `run_extract.sh` was bought by a 2026-08-22
failure. The load-bearing ones:

| var | value | why |
|---|---|---|
| `HOME` | `$ROOT/work/home_v16_$SHARD` | the container mounts real home read-only; Triton and Inductor write `$HOME/.cache` directly and die `EACCES` **after** the model loads, so it reads as a model problem. **Per-shard**, or four shards race in the compile cache |
| `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE` | `1` | a compute node has no egress; without it the loader waits on huggingface.co and times out |
| `VLLM_WORKER_MULTIPROC_METHOD` | `spawn` | vLLM's default fork method raises inside CUDA here |
| `WRITTEN_MAX_OUTPUT_TOKENS` | `2400` | 800 is what the AWS wire pins, and long classical titles exceed it legitimately |
| `WRITTEN_GPU_MEMORY_UTILIZATION` | `0.95` | |

---

## 7. Troubleshooting

| symptom | cause | fix |
|---|---|---|
| **"There are no suitable hosts", pending for hours** | `gmodel=NVIDIAA100_SXM4` is **truncated**. The real string is `NVIDIAA100_SXM4_80GB`; `lshosts -gpu` truncates its column to 15 chars, which is what makes the short form look right | use `submit_extract.sh`. **Cost the v16 run 18 hours on 2026-08-24.** Narrow with `bhosts -R "<clause>"` to prove the resource clause is satisfiable before blaming the cluster |
| Job dies instantly, no GPU touched | submitted with no shard argument; `run_extract.sh` opens `SHARD=$1` under `set -u` | `submit_extract.sh` passes it |
| Acceptance ~9% instead of ~90% | `repair_offsets` skipped between schema and semantic validation | run it exactly as `gateway._accept` does |
| Many `output_overflow` | the 800-token AWS ceiling meets long titles | `WRITTEN_MAX_OUTPUT_TOKENS=2400` |
| *Every* batch `output_overflow` | prompt carries one item, schema permits eight, model pads to the cap | `sequence_schema` sets `maxItems: 1` |
| `User not in the specified user group` | `-G` guessed from the storage path | `groups \| grep ^compute-` |
| `Error near "exec": incorrect section name` | unquoted hostname in `select[]` — LSF reads hyphens as operators | `select[hname!='compute1-exec-399']`, quoted |
| Container chokes parsing the job script | the vLLM image entrypoint parses its argument as JSON config | `LSF_DOCKER_ENTRYPOINT=/bin/bash` |
| `scp`: "remote mkdir … No such file or directory" | client node has no storage mounted | walk the path (§2) |
| A larger model is *worse* | 4-bit AWQ damages low-frequency multilingual knowledge; **size is not the axis, task shape is** | a newer 9B beats an older 72B here |
| `ModuleNotFoundError: jsonschema` locally | system python lacks the validator | `PYTHONPATH=semantic/src semantic/.venv/bin/python` |

**A history file records what was typed, not what succeeded.** `~/.bash_history`
carried a shorter storage path that had never worked; the thing that settles a
path is the filesystem.

---

## 8. State, 2026-08-24

**v16 extracted and validated** — 4,187 rows, **3,603 accepted (86.1%)**, 10,274
mentions, 7,370 offsets repaired. Against v14's 5,387 / 4,832 (89.7%) / 13,833 —
**not directly comparable**: v16 excludes `recommendation` rows and applies the
calendar gate and the 150-subscriber floor, so it is a different corpus.

Already in the database from v14: 9,486 presumed terms, 6,991 relations, 19,599
observation mentions all joined to observations, 393,937 mappings.

**Known stale:** `ris_corpus_probe.py` pins schema v2 / request v1 while the
contract is on v4 / request_v2. **`0309` does not exist** — it is referenced by
`CLAUDE.md` and by `0308`/`0310`, but the numbering jumps; the plaintext filing
it describes lives in `0311`/`0312`/`0314`.
