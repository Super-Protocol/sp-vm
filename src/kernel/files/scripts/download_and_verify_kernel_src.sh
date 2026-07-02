#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# KERNEL_VERSION
# KERNEL_SHA256

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";


function create_dirs() {
    log_info "creating an appropriate directories";
    mkdir -p "$BUILDROOT/src" || log_fail "failed to create an appropriate directories";
}

function download_kernel() {
    log_info "downloading kernel"
    curl \
        -Ss \
        --fail \
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$KERNEL_VERSION.tar.gz" \
        > "$BUILDROOT/src/linux-${KERNEL_VERSION}.tar.gz"\
        || log_fail "failed to download kernel";
}

function download_kernel_checksums() {
    log_info "preparing kernel checksums"
    echo "$KERNEL_SHA256  linux-$KERNEL_VERSION.tar.gz" \
        > "$BUILDROOT/src/linux-$KERNEL_VERSION.sha256" \
        || log_fail "failed to prepare kernel checksums";
}

function verify_kernel_checksum() {
    log_info "verifying kernel checksums"
    pushd "$BUILDROOT/src";
    sha256sum -c "linux-$KERNEL_VERSION.sha256" \
        || log_fail "failed to verify kernel checksum";
    popd;
}

function unarchive_kernel() {
    log_info "unarchiving kernel";
    pushd "$BUILDROOT/src";
    tar -xf "linux-$KERNEL_VERSION.tar.gz";
    popd;
}

create_dirs;
download_kernel;
download_kernel_checksums;
verify_kernel_checksum;
unarchive_kernel;
