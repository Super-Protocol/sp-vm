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
    chroot "${OUTPUTDIR}" /bin/bash -lc 'export NX_DAEMON=false NX_ADD_PLUGINS=false NX_NO_CLOUD=true; cd /opt/swarm-cloud && pnpm install --frozen-lockfile';

    log_info "building swarm-cloud-api";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/swarm-cloud && pnpm nx build swarm-cloud-api --skip-nx-cache --output-style=stream --verbose';

    log_info "building swarm-node";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/swarm-cloud && pnpm nx build swarm-node --skip-nx-cache --output-style=stream --verbose';

    log_info "publishing built artifacts to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'set -e; mkdir -p /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api /usr/local/lib/swarm-cloud/dist/apps/swarm-node';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-cloud-api/dist/* /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api/';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-node/dist/* /usr/local/lib/swarm-cloud/dist/apps/swarm-node/';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/package.json /usr/local/lib/swarm-cloud/package.json';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/pnpm-lock.yaml /usr/local/lib/swarm-cloud/pnpm-lock.yaml || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/pnpm-workspace.yaml /usr/local/lib/swarm-cloud/pnpm-workspace.yaml || true';

    log_info "installing production-only Node.js dependencies (no optional) in app dist folders";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api && pnpm install --prod --no-optional --lockfile-dir=/usr/local/lib/swarm-cloud';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /usr/local/lib/swarm-cloud/dist/apps/swarm-node && pnpm install --prod --no-optional --lockfile-dir=/usr/local/lib/swarm-cloud';

    log_info "removing sources from /opt/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'rm -rf /opt/swarm-cloud || true';
}

chroot_init;
build_swarm_cloud;
chroot_deinit;
