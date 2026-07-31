#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function setup_runtime_tools() {
    log_info "creating policy-rc.d to prevent daemon autostart in chroot"
    printf '#!/bin/sh\nexit 101\n' > "${OUTPUTDIR}/usr/sbin/policy-rc.d"
    chmod +x "${OUTPUTDIR}/usr/sbin/policy-rc.d"
}

chroot_init
setup_runtime_tools
chroot_deinit
