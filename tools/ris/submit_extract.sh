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
  if [ ! -f "$WORK/v16_shard_$s.jsonl" ]; then
    echo "refusing: $WORK/v16_shard_$s.jsonl is not staged" >&2
    exit 1
  fi
done

for s in "${SHARDS[@]}"; do
  bsub -q general -G compute-gfwu -n 8 -M 64GB \
       -R "rusage[mem=64GB]" \
       -R "select[hname!='compute1-exec-399']" \
       -gpu "num=1:gmodel=NVIDIAA100_SXM4_80GB" \
       -R "gpuhost" \
       -a "docker(vllm/vllm-openai:v0.27.1)" \
       -J "wx$s" \
       -o "$WORK/extract_v16_$s.log" \
       bash "$WORK/run_extract.sh" "$s"
done

echo
bjobs -w
