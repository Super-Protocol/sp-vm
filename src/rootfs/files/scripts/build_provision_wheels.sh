#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function build_provision_wheels() {
    log_info "building provision-plugin-sdk wheel inside rootfs"
    chroot "$OUTPUTDIR" /bin/bash -lc 'python3 -m pip install --break-system-packages build wheel'
    chroot "$OUTPUTDIR" /bin/bash -lc 'mkdir -p /opt/provision-wheels && cd /etc/swarm-cloud/services/provision-plugin-sdk && python3 -m build --wheel --outdir /opt/provision-wheels'
    chroot "$OUTPUTDIR" /bin/bash -lc 'ls -l /opt/provision-wheels'
}

chroot_init
build_provision_wheels
chroot_deinit
