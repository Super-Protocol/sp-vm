# Tooling for scripts/azure/upload_gallery_image.sh: Azure CLI, azcopy, qemu-img.
FROM ubuntu:24.04

ARG AZURE_CLI_VERSION=2.90.0
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
        python3-venv \
        qemu-utils \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/azure-cli \
    && /opt/azure-cli/bin/pip install --no-cache-dir --disable-pip-version-check \
        "azure-cli==${AZURE_CLI_VERSION}" \
    && ln -s /opt/azure-cli/bin/az /usr/local/bin/az

RUN mkdir -p /opt/azcopy \
    && curl -sfL https://aka.ms/downloadazcopy-v10-linux \
        | tar -xz -C /opt/azcopy --strip-components=1 \
    && ln -s /opt/azcopy/azcopy /usr/local/bin/azcopy
