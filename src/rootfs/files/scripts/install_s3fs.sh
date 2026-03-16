#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh";

function install_s3fs() {
    log_info "installing s3fs";
    chroot "$OUTPUTDIR" apt-get install -y s3fs;
}

chroot_init;
install_s3fs;
chroot_deinit;
