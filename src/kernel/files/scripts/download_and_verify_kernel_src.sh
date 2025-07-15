#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# KERNEL_VERSION

# private
BUILDROOT="/buildroot";
KERNEL_VERSION_MAJOR="$(awk -F '.' '{print $1}' <<< "$KERNEL_VERSION")";

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
        "https://cdn.kernel.org/pub/linux/kernel/v$KERNEL_VERSION_MAJOR.x/linux-$KERNEL_VERSION.tar.xz" \
        > "$BUILDROOT/src/linux-${KERNEL_VERSION}.tar.xz"\
        || log_fail "failed to download kernel";
}

function download_kernel_checksums() {
    log_info "downloading kernel checksums"
    curl \
        -Ss \
        --fail \
        "https://cdn.kernel.org/pub/linux/kernel/v$KERNEL_VERSION_MAJOR.x/sha256sums.asc" \
        | grep "linux-$KERNEL_VERSION.tar.xz" \
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
    tar -xf "linux-$KERNEL_VERSION.tar.xz";
    popd;
}

create_dirs;
download_kernel;
download_kernel_checksums;
verify_kernel_checksum;
unarchive_kernel;
