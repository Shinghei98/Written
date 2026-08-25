#!/bin/bash
# Submit the four extraction shards, from the cluster login node.
#
# **This exists because the form in `SUBMIT.md` could not run**, and had been
# pending for eighteen hours on 2026-08-24 before anyone looked at why. Two
# defects, both in the block that file gives as copy-and-paste:
#
#   no shard argument   `run_extract.sh` opens `SHARD=$1` under `set -u`, so a
#                       submission without one dies before the GPU is touched.
#                       The four-job form was described in prose at the foot of
#                       SUBMIT.md and never written as a command.
#   gmodel truncated    `-gpu "num=1:gmodel=NVIDIAA100_SXM4"` matches no host.
#                       The real string is `NVIDIAA100_SXM4_80GB`;
#                       `lshosts -gpu` truncates its column to 15 characters,
#                       which is what makes the short form look correct.
#                       LSF reports this as **"There are no suitable hosts for
#                       the job"** — indistinguishable from a busy cluster, and
#                       `run_relabel.sh` already carried the warning: *"a
#                       truncated one matches nothing and reads as scarcity."*
#
# **`-oo` rather than `-o`, and that is a third one.** `-o` *appends*, so a run
# submitted under a log name a previous run already used writes beneath it —
# and `tail` then shows the last run's ending as though it were this one's
# progress. Found on 2026-08-24 with five jobs queued against logs holding a
# completed pass. `-oo` overwrites, so the file means one run.
#
# The GPU spec below is the one that has actually completed a job here: the
# relabel pass ran to "Successfully completed" on `compute1-exec-401` with it.
#
# **`-R "gpuhost"` rather than the group's `gfwu_t1_gpus` counter**, and that is
# a decision. The counter reads `TOTAL 1.0` cluster-wide, so reserving it serialises
# four shards onto one GPU — the opposite of what sharding is for. If the
# allocation is raised later, the counter is the better request.
#
# **The image stays pinned.** `v0.27.1` is the vLLM release the contract
# attests; `latest` can move under a run whose whole purpose is to be
# comparable with the last one.
#
# Usage, from the login node:
#     bash tools/ris/submit_extract.sh          # all four shards
#     bash tools/ris/submit_extract.sh 02       # just one
set -euo pipefail

ROOT=/storage2/fs1/erichuang/Active/Users/David/written
WORK=$ROOT/work

# **The version is read out of `run_extract.sh`, never written again here.**
# Two literals would be two places to edit, and this is the one that would be
# forgotten: the staged-shard check below and the job's own input path would
# then disagree about which file is the shard, and the refusal would name a
# name nothing had ever written. Grepped rather than sourced — sourcing that
# script runs it, and it opens `$1` under `set -u`.
WANT=$(grep -m1 '^WANT=' "$WORK/run_extract.sh" | cut -d= -f2)
VER=${WANT##*_}
if [ -z "$VER" ]; then
  echo "refusing: cannot read the prompt version from $WORK/run_extract.sh" >&2
  exit 1
fi
echo "prompt version: $WANT  (paths carry $VER)"

export LSF_DOCKER_ENTRYPOINT=/bin/bash
export LSF_DOCKER_VOLUMES="/storage2/fs1/erichuang/Active:/storage2/fs1/erichuang/Active"

SHARDS=("$@")
if [ ${#SHARDS[@]} -eq 0 ]; then
  SHARDS=(00 01 02 03)
fi

# **Refuse before submitting rather than after scheduling.** A missing shard
# costs an hour of queue time to discover otherwise, and the job's own contract
# check cannot run until a host has been found.
for s in "${SHARDS[@]}"; do
  if [ ! -f "$WORK/${VER}_shard_$s.jsonl" ]; then
    echo "refusing: $WORK/${VER}_shard_$s.jsonl is not staged" >&2
    exit 1
  fi
done

for s in "${SHARDS[@]}"; do
  bsub -q general -G compute-gfwu -n 8 -M 64GB \
       -R "rusage[mem=64GB]" \
       -R "select[hname!='compute1-exec-399' && hname!='compute1-exec-394']" \
       -gpu "num=1:gmodel=NVIDIAA100_SXM4_80GB" \
       -R "gpuhost" \
       -a "docker(vllm/vllm-openai:v0.27.1)" \
       -J "wx$s" \
       -oo "$WORK/extract_${VER}_$s.log" \
       bash "$WORK/run_extract.sh" "$s"
done

echo
bjobs -w
