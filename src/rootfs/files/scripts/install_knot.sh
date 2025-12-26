#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_knot() {
    log_info "installing Knot DNS into VM rootfs"

    # Base tools and add-apt-repository support
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get update'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get install -y --no-install-recommends software-properties-common ca-certificates'

    # Add upstream PPA and install knot
    chroot "$OUTPUTDIR" /bin/bash -lc '
        set -e;
        add-apt-repository -y ppa:cz.nic-labs/knot-dns;
        apt-get update;
        apt-get install -y knot;
    '

    chroot "$OUTPUTDIR" /bin/bash -lc 'apt-get clean'
}

chroot_init
install_knot
chroot_deinit
