#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# KERNEL_VERSION

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
    log_info "downloading kernel checksums"
    echo "191dc5aae14a4223f0d5ce4e88cbbd29f0377703b9f0b70d4903734de641fb6a  linux-$KERNEL_VERSION.tar.gz" \
        > "$BUILDROOT/src/linux-$KERNEL_VERSION.sha256" \
        || log_fail "failed to download kernel checksums";
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
