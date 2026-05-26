#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# public, optional
# $1 - NODE_EXPORTER_VERSION - version to install
# $2 - TARGETARCH - Docker build target architecture

# private
BUILDROOT="/buildroot";
NODE_EXPORTER_VERSION="${1:-1.11.1}";
TARGETARCH="${2:-}";

# init logging;
source "${BUILDROOT}/files/scripts/log.sh";

function normalize_arch() {
    local ARCH="${1}";

    case "${ARCH}" in
        amd64|arm64)
            echo "${ARCH}";
            ;;
        x86_64)
            echo "amd64";
            ;;
        aarch64)
            echo "arm64";
            ;;
        *)
            log_fail "unsupported node_exporter architecture: ${ARCH}";
            return 1;
            ;;
    esac
}

function detect_arch() {
    if [ -n "${TARGETARCH}" ]; then
        normalize_arch "${TARGETARCH}";
        return;
    fi

    normalize_arch "$(uname -m)";
}

function install_node_exporter() {
    local ARCH;
    ARCH="$(detect_arch)";

    local RELEASE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}";
    local FILENAME="${RELEASE}.tar.gz";
    local URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${FILENAME}";
    local TMPDIR;
    TMPDIR="$(mktemp -d)";

    log_info "downloading node_exporter ${NODE_EXPORTER_VERSION} for linux-${ARCH}";
    wget -q -O "${TMPDIR}/${FILENAME}" "${URL}";

    log_info "installing node_exporter";
    tar -xzf "${TMPDIR}/${FILENAME}" -C "${TMPDIR}";
    install -m 0755 "${TMPDIR}/${RELEASE}/node_exporter" "${OUTPUTDIR}/usr/local/bin/node_exporter";
    rm -rf "${TMPDIR}";

    local INSTALLED_VERSION;
    INSTALLED_VERSION="$("${OUTPUTDIR}/usr/local/bin/node_exporter" --version 2>&1 | head -n 1 || true)";
    if [ -z "${INSTALLED_VERSION}" ]; then
        log_fail "node_exporter installation failed";
        return 1;
    fi

    log_info "${INSTALLED_VERSION} installed successfully";
}

install_node_exporter;
