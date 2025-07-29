#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh";

function refresh_ca_certs() {
    log_info "refreshing ca certs";
    chroot "$OUTPUTDIR" /bin/bash -c 'update-ca-certificates --fresh';
}

chroot_init;
refresh_ca_certs;
chroot_deinit;
