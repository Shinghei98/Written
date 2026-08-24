#!/bin/bash
# The focused label pass, as an LSF job.
#
# **Kept in the repository rather than only on the cluster.** Every earlier
# job script lived at /storage2/.../work and nowhere else, so the settings
# bought by four "no suitable hosts" refusals and a CUDA fork error existed in
# exactly one place. They are here now:
#
#   -R "gpuhost"          without it LSF finds no host, and the message names
#                         no reason. `gpuhost` already expands to a select
#                         section, so a host exclusion must be a SEPARATE -R.
#   LSF_DOCKER_ENTRYPOINT the vLLM image's entrypoint parses its argument as a
#                         JSON config and chokes on a job script.
#   HOME                  Triton and Inductor ignore HF_HOME and write to
#                         ~/.cache, which is not writable on a compute node.
#   spawn                 vLLM's default fork method raises inside CUDA here.
#   NVIDIAA100_SXM4_80GB  the real gmodel string; a truncated one matches
#                         nothing and reads as scarcity.
set -euo pipefail

ROOT=/storage2/fs1/erichuang/Active/Users/David/written
export HOME="$ROOT/work/home"
export HF_HOME="$ROOT/models/hf"
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export MODEL_PATH="$ROOT/models/qwen3.5-9b"
export TOKENIZERS_PARALLELISM=false
mkdir -p "$HOME" "$HF_HOME"

cd "$ROOT/work"
python3 ris_relabel.py "$ROOT/work/relabel.jsonl" "$ROOT/work/relabel_out.jsonl"
