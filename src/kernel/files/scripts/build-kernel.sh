#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# KERNEL_VERSION

# private
BUILDROOT="/buildroot";
OUTPUTROOT="/output";
ARCH="$(uname -m)";
KERNEL_SRC="$BUILDROOT/src/linux-$KERNEL_VERSION";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function copy_previous_arfifacts() {
    log_info "staring copying previous artifacts";
    cp "$BUILDROOT/files/initramfs.cpio.gz" "$KERNEL_SRC/";
    cp "$BUILDROOT/files/configs/fragments/$ARCH/.config" "$KERNEL_SRC/";
}

function build_kernel() {
    pushd "$KERNEL_SRC";
    log_info "staring building kernel";
    make \
        -j "$(nproc)" \
        "ARCH=$ARCH" \
        || log_fail "failed to build kernel";
    popd;
}

function install_modules() {
    pushd "$KERNEL_SRC";
    log_info "staring installing modules";
    make \
        -j "$(nproc)" \
        INSTALL_MOD_STRIP=1 \
        "ARCH=$ARCH" \
        "INSTALL_MOD_PATH=$KERNEL_SRC" \
        modules_install \
        || log_fail "failed to install kernel modules";
    popd;
}

function make_deb_artifacts() {
    pushd "$KERNEL_SRC";
    log_info "staring creating deb artifacts";
    make \
        -j "$(nproc)" \
        "ARCH=$ARCH" \
        bindeb-pkg \
        || log_fail "failed to create deb artifacts";
    popd;
}

function move_artifacts() {
    log_info "moving artifacts";
    mkdir -p "$OUTPUTROOT";
    mkdir -p "$OUTPUTROOT/deb";
    mkdir -p "$OUTPUTROOT/boot";
    cp "$KERNEL_SRC"/../*.deb "$OUTPUTROOT/deb/";
    install \
        --mode 0644 \
        -D "$KERNEL_SRC/arch/$ARCH/boot/bzImage" \
        "$OUTPUTROOT/boot/vmlinuz-$KERNEL_VERSION-nvidia-gpu-confidential";
    cp "$KERNEL_SRC/.config" "$OUTPUTROOT/boot/config-$ARCH-nvidia-gpu-confidential";
}

copy_previous_arfifacts;
build_kernel;
install_modules;
make_deb_artifacts;
move_artifacts;
