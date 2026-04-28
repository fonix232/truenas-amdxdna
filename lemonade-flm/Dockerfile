# Layer FastFlowLM on top of the official Lemonade image.
# The official image ships without FLM (the .deb install is in the source
# Dockerfile but omitted from published builds). This image adds it back.
#
# FLM version is pinned by the version already baked into the official image's
# backend_versions.json, so Lemonade and FLM stay in sync automatically.

FROM ghcr.io/lemonade-sdk/lemonade-server:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
        jq \
        curl \
        software-properties-common \
    && add-apt-repository -y ppa:amd-team/xrt \
    && apt-get update \
    && FLM_VERSION=$(jq -r '.flm.npu' /opt/lemonade/resources/backend_versions.json) \
    && FLM_VERSION_NUM=$(echo "$FLM_VERSION" | sed 's/^v//') \
    && curl -fsSL -o /tmp/fastflowlm.deb \
        "https://github.com/FastFlowLM/FastFlowLM/releases/download/${FLM_VERSION}/fastflowlm_${FLM_VERSION_NUM}_ubuntu24.04_amd64.deb" \
    && apt-get install -y /tmp/fastflowlm.deb \
    && rm /tmp/fastflowlm.deb \
    && rm -rf /var/lib/apt/lists/*
