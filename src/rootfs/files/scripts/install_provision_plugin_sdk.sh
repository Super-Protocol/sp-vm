#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_provision_sdk() {
    log_info "installing provision-plugin-sdk into VM Python environment"
    # Install from prebuilt wheels if present; otherwise from source inside rootfs
    chroot "$OUTPUTDIR" /bin/bash -lc 'shopt -s nullglob; set -e; files=(/opt/provision-wheels/*.whl); if (( ${#files[@]} )); then python3 -m pip install --break-system-packages "${files[@]}"; else echo "No wheels found, installing from source"; python3 -m pip install --break-system-packages /etc/swarm-cloud/provision-plugin-sdk; fi'
}

chroot_init
install_provision_sdk
chroot_deinit
