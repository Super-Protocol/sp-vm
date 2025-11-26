#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init logging
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

function build_swarm_cloud() {
    log_info "enabling corepack inside rootfs";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'corepack enable';

    log_info "installing Node.js dependencies with pnpm";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'export NX_DAEMON=false NX_ADD_PLUGINS=false NX_NO_CLOUD=true; cd /etc/swarm-cloud && pnpm install --frozen-lockfile';

    log_info "building swarm-cloud-api";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /etc/swarm-cloud && pnpm nx build swarm-cloud-api --skip-nx-cache --output-style=stream --verbose';

    log_info "building swarm-node";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /etc/swarm-cloud && pnpm nx build swarm-node --skip-nx-cache --output-style=stream --verbose';
}

chroot_init;
build_swarm_cloud;
chroot_deinit;
