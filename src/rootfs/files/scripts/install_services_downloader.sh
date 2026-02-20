#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init logging;
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

function install_services_downloader() {
    log_info "installing services-downloader dependencies (npm ci)";
    chroot "${OUTPUTDIR}" /bin/bash -c 'cd /usr/local/lib/services-downloader && npm ci';

    # quick smoke test prints help via node directly
    chroot "${OUTPUTDIR}" /bin/bash -c 'node /usr/local/lib/services-downloader/src/index.js --help >/dev/null || true';
}

chroot_init;
install_services_downloader;
chroot_deinit;
