# Tooling for scripts/azure/ensure_gallery_image.sh: Azure CLI, azcopy, the
# Storj uplink client and zstd.
FROM ubuntu:24.04

ARG AZURE_CLI_VERSION=2.90.0
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        python3 \
        python3-venv \
        unzip \
        zstd \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/azure-cli \
    && /opt/azure-cli/bin/pip install --no-cache-dir --disable-pip-version-check \
        "azure-cli==${AZURE_CLI_VERSION}" \
    && ln -s /opt/azure-cli/bin/az /usr/local/bin/az

RUN mkdir -p /opt/azcopy \
    && curl -sfL https://aka.ms/downloadazcopy-v10-linux \
        | tar -xz -C /opt/azcopy --strip-components=1 \
    && ln -s /opt/azcopy/azcopy /usr/local/bin/azcopy

RUN curl -sfL -o /tmp/uplink.zip \
        https://github.com/storj/storj/releases/latest/download/uplink_linux_amd64.zip \
    && unzip -q -o /tmp/uplink.zip -d /tmp \
    && install -m 0755 /tmp/uplink /usr/local/bin/uplink \
    && rm -f /tmp/uplink.zip /tmp/uplink
