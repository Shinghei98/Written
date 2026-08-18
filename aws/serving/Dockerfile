# The Qwen serving image: vLLM pinned to an exact wheel, on an exact CUDA base.
#
# **A custom image rather than SageMaker LMI.** LMI is a fine container and it
# pins vLLM only indirectly — the deployment manifest would record AWS's image
# digest and infer the engine version from it. What has to be attestable here is
# *which vLLM built this answer*, so the wheel is named and the digest is ours.
#
# Nothing is fetched from Hugging Face at boot. The weights are staged into S3
# beforehand, checksummed, and mounted by SageMaker: a boot-time fetch would put
# a third party in the startup path of a GPU billed by the minute, make the model
# a moving target because a repository can be updated under a tag, and leave no
# record of what was actually loaded.
ARG CUDA_BASE=nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04
FROM ${CUDA_BASE}

# Pinned by version and recorded in the deployment manifest. Change this and the
# manifest changes with it, which is the point.
ARG VLLM_VERSION=0.11.0

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --break-system-packages "vllm==${VLLM_VERSION}"

# `HF_HUB_OFFLINE` is belt to the braces of an endpoint with no egress: if a
# boot-time fetch is ever attempted it fails loudly rather than quietly
# succeeding and changing what is deployed.

COPY aws/serving/serve.py /opt/serve.py

# SageMaker speaks to a container on 8080 through /ping and /invocations,
# whatever the engine behind it is.
EXPOSE 8080
ENV MODEL_PATH=/opt/ml/model \
    VLLM_VERSION=${VLLM_VERSION}
ENTRYPOINT ["python3", "/opt/serve.py"]
