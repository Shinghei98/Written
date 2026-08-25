#!/bin/bash
# One extraction shard on one A100, under David/written.
#
# **Descended from `run_shard.sh`, which is the version that ran**, not from
# the relabel job. An earlier draft of this file was written from the relabel
# flags and was missing every cache redirection below; each was paid for by a
# failure on 2026-08-22:
#
#   HOME redirected     the container mounts the real home read-only, and
#                       HF_HOME/XDG_CACHE_HOME were not enough — vLLM pulls in
#                       Triton and Inductor, which write to $HOME/.cache
#                       directly and died with EACCES *after* the model had
#                       been found, so it read as a model problem.
#   per-shard HOME      four shards sharing one HOME race in the compile cache.
#   spawn               vLLM's default fork method raises inside CUDA here.
#   *_OFFLINE=1         a compute node has no egress; without it the loader
#                       waits on huggingface.co and times out.
#   2400 output tokens  800 is what the AWS wire pins and 1,020 of 5,387 rows
#                       truncated at it. Long classical titles exceed it
#                       legitimately.
#
# Usage:  run_extract.sh <shard>      e.g. 00 01 02 03
set -euo pipefail

ROOT=/storage2/fs1/erichuang/Active/Users/David/written
SHARD=$1

# **The prompt version this job is.** A literal — the long note at the gate
# below says why it must not be read from the contract.
WANT=qwen_extractor_v19
# **Every versioned path derives from it, and that is the second half of the
# same lesson.** The shard read, the results written and the compile cache all
# said `v16` while the prompt had moved to v18, so a v18 run landed in files
# that read as the previous one — the defect the gate exists to catch, one
# layer further out, where the gate cannot see it. One literal moves per
# release and the filenames follow it.
VER=${WANT##*_}

export HOME=$ROOT/work/home_${VER}_$SHARD
export HF_HOME=$ROOT/work/hf XDG_CACHE_HOME=$HOME/.cache
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export MODEL_PATH=$ROOT/models/qwen3.5-9b
export VLLM_CACHE_ROOT=$HOME/.cache/vllm
export OUTLINES_CACHE_DIR=$HOME/.cache/outlines
export TRITON_CACHE_DIR=$HOME/.cache/triton
export TORCHINDUCTOR_CACHE_DIR=$HOME/.cache/inductor
export WRITTEN_GPU_MEMORY_UTILIZATION=0.95
export WRITTEN_MAX_NUM_SEQS=256
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export WRITTEN_MAX_OUTPUT_TOKENS=2400
mkdir -p "$HOME/.cache" "$VLLM_CACHE_ROOT" "$OUTLINES_CACHE_DIR" \
         "$TRITON_CACHE_DIR" "$TORCHINDUCTOR_CACHE_DIR" "$HF_HOME" "$ROOT/out"

cd "$ROOT/work"

# **The prompt version is asserted, not assumed.** The whole point of this run
# is that it is v16 — the ten categorisation rules the owner's labels bought.
# A contract left from the last run would produce a v14 corpus that reads as a
# v16 result, and nothing downstream would say so. Checked before the GPU is
# touched, so a stale stage costs a second rather than an hour.
# **A literal that moves once per release, and it has to be.** Reading the
# version out of the contract would make this agree with whatever was staged,
# which is the one thing it exists to catch: a stale contract produces a corpus
# of the previous prompt that reads as this one's result.
# `WANT` is set at the top, where the paths that derive from it are built.
GOT=$(python3 -c "import json;print(json.load(open('compiled_semantic_contract_v1.json'))['versions']['prompt'])")
if [ "$GOT" != "$WANT" ]; then
  echo "refusing: contract on the cluster says $GOT, this job is $WANT" >&2
  exit 1
fi
echo "shard $SHARD  contract prompt version: $GOT"

nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
python3 ris_extract.py "$ROOT/work/${VER}_shard_$SHARD.jsonl" "$ROOT/out/${VER}_results_$SHARD.jsonl"
