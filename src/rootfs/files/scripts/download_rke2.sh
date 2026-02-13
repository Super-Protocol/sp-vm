#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
RKE2_VERSION="v1.35.0+rke2r3";
SHA_CHECKSUMS_TXT="f2e78be16715b30e93a8aea4e7d64eda4a59c2615fb3c3a2f35a7f464fdbb384";
SHA_INSTALL_SH="2d24db2184dd6b1a5e281fa45cc9a8234c889394721746f89b5fe953fdaaf40a";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function download_rke2() {
    log_info "downloading rke2 install scripts"
    mkdir -p "$OUTPUTDIR/root/rke2";
    wget \
        "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2-images.linux-amd64.tar.zst" \
        -O "$OUTPUTDIR/root/rke2/rke2-images.linux-amd64.tar.zst";
    wget \
        "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2.linux-amd64.tar.gz" \
        -O "$OUTPUTDIR/root/rke2/rke2.linux-amd64.tar.gz";
    wget \
        "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/sha256sum-amd64.txt" \
        -O "$OUTPUTDIR/root/rke2/sha256sum-amd64.txt";
    wget \
        "https://raw.githubusercontent.com/rancher/rke2/refs/tags/${RKE2_VERSION}/install.sh" \
        -O "$OUTPUTDIR/root/rke2/rke2-install.sh";
}

function validate_checksum() {
    log_info "validating checksums";
    pushd "$OUTPUTDIR/root/rke2";
    echo "$SHA_CHECKSUMS_TXT sha256sum-amd64.txt" | sha256sum --check
    echo "$SHA_INSTALL_SH rke2-install.sh" | sha256sum --check
    popd;
}

download_rke2;
validate_checksum;
