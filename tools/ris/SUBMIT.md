# Submitting a job to RIS

Two jobs live here: the full **extraction** pass and the focused **relabel**
pass. They differ only in the script and the files staged; every LSF flag below
was bought by a failed submission and the reasons are at the foot of this file.

Open the SSH master once (Duo prompt answered interactively):

    ssh compute1

## The extraction pass

**Staged files, and why each one.** `serve.py` is the production prompt builder
— the run is only meaningful because it is not a reimplementation. The contract
carries the prompt version, so **staging a stale one produces a v14 corpus that
reads as a v16 result**; `run_extract.sh` refuses to start if the contract on
the cluster does not say what the job claims.

**The output schema is named by the contract, never by this file.**
`ris_extract.py:34` reads `versions.output_schema` and loads that filename from
beside itself, so the schema staged has to be the one the contract asks for.
This line named `mention_extract_v4.schema.json` while the contract had already
moved to v5 — **the job dies on a missing file after the stage, at the point
where a GPU has been allocated**, and the version gate cannot catch it because
the gate checks the prompt version and this is a different field. Derive it:

    SCHEMA=$(python3 -c "import json;print(json.load(open('semantic/contracts/compiled_semantic_contract_v1.json'))['versions']['output_schema'].rsplit('/',1)[-1])")

    scp tools/ris_extract.py aws/serving/serve.py \
        semantic/contracts/compiled_semantic_contract_v1.json \
        "semantic/contracts/$SCHEMA" \
        out/ris/v18_shard_0*.jsonl out/ris/v18_shard_fx.jsonl \
        tools/ris/run_extract.sh tools/ris/submit_extract.sh \
        compute1:/storage2/fs1/erichuang/Active/Users/David/written/work/

**`v18` is derived, not typed.** `run_extract.sh` sets `WANT` — the prompt
version the job claims — and every versioned path takes its suffix: the shard
read, the results written, the compile cache, the log. `submit_extract.sh` greps
`WANT` out of `run_extract.sh` rather than keeping a second copy, so one literal
moves per release and the filenames follow. Stage the shards whose name matches
the `WANT` you are running.

**Submit with the script, never a hand-written `bsub`.**

    ssh compute1 'bash /storage2/fs1/erichuang/Active/Users/David/written/work/submit_extract.sh'
    ssh compute1 'bash …/submit_extract.sh 00 01 02 03 fx'   # with the fixtures shard
    ssh compute1 'bash …/submit_extract.sh 02'               # just one

The block that used to sit here was a literal `bsub` and it **could not run**.
Two defects, both in copy-and-paste: it passed `run_extract.sh` no shard
argument, which opens `$1` under `set -u` and dies before the GPU is touched;
and it named `docker(vllm/vllm-openai:latest)` where the contract attests
`v0.27.1` — an unpinned image can move under a run whose whole purpose is to be
comparable with the last one. `submit_extract.sh` carries the form that has
actually completed a job here.

Watch it — the first line of the log is the contract's prompt version, so a
stale stage is visible before any GPU time is spent:

    ssh compute1 'bjobs -w; tail -40 …/work/extract_v18_00.log'

**A missing log file means the job has not started.** The script opens it with
`-oo`, which overwrites; with `-o` LSF appends, and a `tail` then shows the
previous run's ending as though it were this one's progress.

Bring the answers back and validate on the Mac, never on the cluster:

    scp 'compute1:…/written/out/v18_results_0*.jsonl' out/ris/
    PYTHONPATH=semantic/src semantic/.venv/bin/python tools/ris_ingest_results.py \
        out/ris/items_v18.jsonl out/ris/v18_results_0*.jsonl out/ris/verdicts_v18.json

**Then score it, rather than reading it.**

    python3 tools/score_categorisation.py out/ris/verdicts_fixtures_v18.json

## Submitting the relabel pass

From the Mac, stage and submit:

    scp tools/ris_relabel.py aws/serving/serve.py out/ris/relabel.jsonl \
        tools/ris/run_relabel.sh \
        compute1:/storage2/fs1/erichuang/Active/Users/David/written/work/

    ssh compute1 'export LSF_DOCKER_ENTRYPOINT=/bin/bash \
      LSF_DOCKER_VOLUMES="/storage2/fs1/erichuang/Active:/storage2/fs1/erichuang/Active" \
      && bsub -q general -G compute-gfwu -n 8 -M 64GB -R "rusage[mem=64GB]" \
         -gpu "num=1:gmodel=NVIDIAA100_SXM4_80GB" -R "gpuhost" \
         -R "select[hname!='compute1-exec-399']" \
         -a "docker(vllm/vllm-openai:latest)" \
         -o /storage2/fs1/erichuang/Active/Users/David/written/work/relabel.log \
         bash /storage2/fs1/erichuang/Active/Users/David/written/work/run_relabel.sh'

Watch it:

    ssh compute1 'bjobs -w; tail -40 /storage2/fs1/erichuang/Active/Users/David/written/work/relabel.log'

Bring the answers back:

    scp compute1:/storage2/fs1/erichuang/Active/Users/David/written/work/relabel_out.jsonl \
        out/ris/

## The two docker exports are load-bearing, and the shell decides whether you have them

**`LSF_DOCKER_ENTRYPOINT=/bin/bash` and a `LSF_DOCKER_VOLUMES` naming
`/storage2` must be exported in the submitting shell, or the job dies in
under a minute with a misleading log.** Measured 2026-08-25 (job 202448):
without them the container has no `/storage2` mount and the vllm image's own
entrypoint fires — `vllm serve` starts with **the LSF spool script as its
model path**, and the log shows an APIServer banner and a JSON decode
traceback that looks like a broken model when the actual failure is a
missing mount. Fifty-one seconds of a scheduled A100, spent before the run
script was ever read.

The trap is that `~/.bashrc` exports its own `LSF_DOCKER_VOLUMES` for the
RStudio jobs — home, scratch1, storage3, **no storage2** — so an
`ssh compute1 'bsub …'` that does not export its own value inherits one that
looks set and mounts the wrong trees. The relabel form above carries both
exports; copy that shape, never a bare `bsub`.

## The group is `compute-gfwu`, and it is not the storage name

`-G` is an LSF user group; `/storage2/fs1/erichuang` is a storage allocation.
They are separate registries and here they do not match — there is no
`compute-erichuang` group at all. Guessing the group from the path costs a
submission that fails with `User not in the specified user group`, which names
no valid alternative. `groups | grep ^compute-` lists what is available, and
`bjobs -a -o "jobid user_group"` says which one past jobs actually used.

(`bhist` is disabled on this deployment — RIS points at the RTM dashboard
instead — so `bjobs -a` is the only way to read job history from the shell.)

## A hostname inside `select[]` must be quoted

`select[hname!=compute1-exec-399]` is refused with *"Error near \"exec\":
incorrect section name, resource name, or resource function name"* — LSF reads
the hyphens as operators and the fragments as resource names. It needs
`select[hname!='compute1-exec-399']`, and through an outer single-quoted `ssh`
command that is written `'"'"'` / `'\''`.

The exclusion itself is worth keeping: `compute1-exec-399` caused four
failures on 2026-08-22 (a CUDA fork error, a driver initialisation failure and
two probe failures) while identical scripts succeeded on 394, 401 and 166.


## The path, and the two jobs that are not the same job

**The path is `/storage2/fs1/erichuang/Active/Users/David/written`,** and a
`scp` failure against it does not mean otherwise.

When it failed on 2026-08-23 the message was *"remote mkdir … No such file or
directory"*, which names the leaf rather than the level that is missing, so the
path looked wrong. `~/.bash_history` carried a shorter form
(`.../Active/written`) and I took that as the correction — **it was a command
that had failed, not a record of one that worked**, and the short path exists
nowhere. The real cause was that the client node had no storage mounted at all.

**A history file records what was typed, not what succeeded.** The thing that
settles a path is the filesystem, and here that meant the SMB mount rather than
the login node.

**The relabel pass and the extraction pass were submitted differently**, and
the flags above descend from the relabel one:

    relabel     -gpu "num=1:gmodel=NVIDIAA100_SXM4_80GB" -R "gpuhost"
                -R "select[hname!='compute1-exec-399']"
                -a "docker(vllm/vllm-openai:latest)"

    extraction  -gpu "num=1:gmodel=NVIDIAA100_SXM4"
                -R "select[gfwu_t1_gpus>0] rusage[mem=64GB,gfwu_t1_gpus=1] span[hosts=1]"
                -a "docker(vllm/vllm-openai:v0.27.1)"      four shards, -J wx00..wx03

The extraction form reserves the group's own GPU counter (`gfwu_t1_gpus`)
rather than asking for a generic `gpuhost`, and **pins the image to the vLLM
release the contract attests** instead of `latest`. Both matter: the counter is
what makes the request schedulable against the group's allocation, and an
unpinned image can move under a run whose whole purpose is to be comparable to
the last one.

## When storage is not mounted

Checked 2026-08-23 from `compute1-client-1`: `df` listed **no storage
filesystem at all**, `mount` showed only `rpc_pipefs`, and
`/storage2/fs1/erichuang`, `/storage3/fs1/gfwu` and
`/storage1/fs1/erichuang` all failed to resolve. Only `/storage1/fs1/gfwu/Active`
resolved, and it could not be listed.

That is not something a job script can work around — the automounter has no map
for the allocation, so nothing can be staged and no container can bind it.
Walking the path one level at a time is what distinguishes the three cases,
because `scp` reports only the leaf:

    ssh compute1 'for p in /storage2 /storage2/fs1 /storage2/fs1/erichuang \
        /storage2/fs1/erichuang/Active /storage2/fs1/erichuang/Active/Users/David/written; do
      [ -d "$p" ] && echo "OK   $p" || { echo "GONE $p"; break; }; done'

A missing **allocation** is a lease or a rename; a missing **leaf** is a
cleaned work tree, which also takes the ~18 GB of model weights at
`$ROOT/models/qwen3.5-9b` with it; a **mounted but unlistable** path is a
credential problem. Only the middle one is recoverable without RIS.
