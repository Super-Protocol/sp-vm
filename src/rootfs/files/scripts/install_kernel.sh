#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function install_kernel() {
    log_info "installing kernel to rootfs";
    chroot "$OUTPUTDIR" /bin/bash -c '/usr/bin/dpkg -i /kernel_deb/*.deb';
}

install_kernel;
