#!/bin/bash

set -euo pipefail

BUILDROOT="/buildroot"
LOCK_DIR="$BUILDROOT/files/configs/npm/pki-components"
INSTALL_ROOT="/usr/local/lib/pki-components"
NVTRUST_PACKAGE="$INSTALL_ROOT/node_modules/@super-protocol/sp-nvtrust-wrapper"
UPLINK_PACKAGE="$INSTALL_ROOT/node_modules/@super-protocol/uplink-nodejs"
UPLINK_PREBUILD="uplink-nodejs-v1.2.20-napi-v7-linux-x64.tar.gz"
UPLINK_PREBUILD_URL="https://github.com/Super-Protocol/uplink-nodejs-sp/releases/download/v1.2.20/$UPLINK_PREBUILD"
UPLINK_PREBUILD_SHA256="3382e0ab17b5415a812d58f1ccba12ca5fbb5f5056098c74a6313b67974659b1"
BINARIES=(
    pki-cert-generator
    pki-sync-client
    pki-vm-measurements
)

# shellcheck disable=SC1091
source "$BUILDROOT/files/scripts/log.sh"
# shellcheck disable=SC1091
source "$BUILDROOT/files/scripts/chroot.sh"

function install_uplink_prebuild() {
    local archive="$OUTPUTDIR/tmp/$UPLINK_PREBUILD"

    [[ -d "$OUTPUTDIR$UPLINK_PACKAGE" ]] \
        || log_fail "locked dependency is missing: @super-protocol/uplink-nodejs"
    log_info "installing locked uplink-nodejs native prebuild"
    wget --quiet --output-document="$archive" "$UPLINK_PREBUILD_URL"
    printf '%s  %s\n' "$UPLINK_PREBUILD_SHA256" "$archive" | sha256sum --check --status
    tar \
        --extract \
        --gzip \
        --file="$archive" \
        --directory="$OUTPUTDIR$UPLINK_PACKAGE" \
        --no-same-owner \
        --no-same-permissions
    rm -f "$archive"
    [[ -f "$OUTPUTDIR$UPLINK_PACKAGE/build/Release/uplink.node" ]] \
        || log_fail "uplink-nodejs prebuild did not contain uplink.node"
}

function install_nvtrust_python_dependencies() {
    [[ -d "$OUTPUTDIR$NVTRUST_PACKAGE" ]] \
        || log_fail "locked dependency is missing: @super-protocol/sp-nvtrust-wrapper"
    log_info "installing sp-nvtrust-wrapper dependencies from its hashed Python lock"
    chroot "$OUTPUTDIR" env \
        PIP_NO_CACHE_DIR=1 \
        SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?}" \
        npm --prefix "$NVTRUST_PACKAGE" run postinstall
}

function install_pki_components() {
    log_info "installing locked PKI npm components"

    rm -rf "${OUTPUTDIR:?}$INSTALL_ROOT"
    install -d "$OUTPUTDIR$INSTALL_ROOT"
    install -m 0644 "$LOCK_DIR/package.json" "$OUTPUTDIR$INSTALL_ROOT/package.json"
    install -m 0644 "$LOCK_DIR/package-lock.json" "$OUTPUTDIR$INSTALL_ROOT/package-lock.json"

    chroot "$OUTPUTDIR" npm ci \
        --prefix "$INSTALL_ROOT" \
        --omit=dev \
        --ignore-scripts \
        --no-audit \
        --no-fund

    rm -f \
        "$OUTPUTDIR$INSTALL_ROOT/package.json" \
        "$OUTPUTDIR$INSTALL_ROOT/package-lock.json" \
        "$OUTPUTDIR$INSTALL_ROOT/node_modules/.package-lock.json"

    # npm lifecycle scripts are disabled above because they are not described
    # by package-lock.json. Run only the two required installers with their
    # external inputs pinned independently.
    install_uplink_prebuild
    install_nvtrust_python_dependencies

    local binary
    for binary in "${BINARIES[@]}"; do
        [[ -e "$OUTPUTDIR$INSTALL_ROOT/node_modules/.bin/$binary" ]] \
            || log_fail "PKI package did not provide executable: $binary"
        ln -sfn \
            "../local/lib/pki-components/node_modules/.bin/$binary" \
            "$OUTPUTDIR/usr/bin/$binary"
    done

    log_info "locked PKI npm components installed successfully"
}

chroot_init
install_pki_components
chroot_deinit
