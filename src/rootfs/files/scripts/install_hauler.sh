#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
HAULER_VERSION="1.1.0";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh";

function download_hauler() {
    log_info "downloading hauler";
    wget \
        "https://get.hauler.dev" \
        -O "$OUTPUTDIR/root/install_hauler.sh";
}

function install_hauler() {
    log_info "installing hauler";
    mkdir -p "$OUTPUTDIR//opt/hauler/.hauler";
    ln -sf "/opt/hauler/.hauler" "$OUTPUTDIR/root/.hauler";
    pushd "$OUTPUTDIR/opt/hauler";
    chroot "$OUTPUTDIR" /bin/bash -c "HAULER_VERSION=$HAULER_VERSION bash /root/install_hauler.sh";
    rm -f "$OUTPUTDIR/root/install_hauler.sh";
    popd;
}

download_hauler;
chroot_init;
install_hauler;
chroot_deinit;
