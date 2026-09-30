# Tooling for the scripts in scripts/azure (ensure_gallery_image.sh,
# run_custom_conf_vm.sh, cluster.sh): Azure CLI, azcopy, the Storj uplink
# client, zstd, and python3-yaml for the cluster specification.
FROM ubuntu:24.04

ARG AZURE_CLI_VERSION=2.90.0
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        openssh-client \
        openssl \
        python3 \
        python3-venv \
        python3-yaml \
        unzip \
        zstd \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/azure-cli \
    && /opt/azure-cli/bin/pip install --no-cache-dir --disable-pip-version-check \
        "azure-cli==${AZURE_CLI_VERSION}" \
    && ln -s /opt/azure-cli/bin/az /usr/local/bin/az

# azure-cli 2.90 pulls requests 2.34. Importing requests.structures while
# requests.auth is still initializing makes `az network nsg rule create` die.
# The venv's site-packages sitecustomize is hidden by Ubuntu's copy in
# /usr/lib/python3.12, so the preload has to live there. 2.32.3 still
# satisfies azure-cli.
RUN /opt/azure-cli/bin/pip install --no-cache-dir --disable-pip-version-check \
        'requests==2.32.3' \
    && printf '\n%s\n' \
        'try:' \
        '    import requests' \
        '    from msrest.polling.poller import LROPoller' \
        'except ModuleNotFoundError:' \
        '    pass' \
        >> /usr/lib/python3.12/sitecustomize.py \
    && rm -f /opt/azure-cli/lib/python3.12/site-packages/sitecustomize.py

# buildx sets TARGETARCH (amd64 or arm64). The short azcopy link and a
# hardcoded amd64 uplink crash under Rosetta on Apple Silicon.
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) AZCOPY_URL=https://aka.ms/downloadazcopy-v10-linux; UPLINK_ARCH=amd64 ;; \
      arm64) AZCOPY_URL=https://aka.ms/downloadazcopy-v10-linux-arm64; UPLINK_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/azcopy \
    && curl -sfL "$AZCOPY_URL" \
        | tar -xz -C /opt/azcopy --strip-components=1 \
    && ln -s /opt/azcopy/azcopy /usr/local/bin/azcopy \
    && curl -sfL -o /tmp/uplink.zip \
        "https://github.com/storj/storj/releases/latest/download/uplink_linux_${UPLINK_ARCH}.zip" \
    && unzip -q -o /tmp/uplink.zip -d /tmp \
    && install -m 0755 /tmp/uplink /usr/local/bin/uplink \
    && rm -f /tmp/uplink.zip /tmp/uplink
