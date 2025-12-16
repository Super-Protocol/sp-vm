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

    log_info "building swarm-cloud-ui";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/swarm-cloud && pnpm nx build swarm-cloud-ui --skip-nx-cache --output-style=stream --verbose';

    log_info "publishing built swarm-node artifacts to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'set -e; mkdir -p /usr/local/lib/swarm-cloud/dist/apps/swarm-node';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-node/dist/* /usr/local/lib/swarm-cloud/dist/apps/swarm-node/';

    log_info "publishing built swarm-cloud-api artifacts to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'set -e; mkdir -p /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-cloud-api/dist/* /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api/';

    log_info "publishing built swarm-cloud-ui artifacts to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'set -e; mkdir -p /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-cloud-ui/. /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui/';
    # Remove app-local node_modules with broken pnpm symlinks; use workspace-level node_modules instead
    chroot "${OUTPUTDIR}" /bin/bash -lc 'rm -rf /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui/node_modules || true';

    log_info "copying shared UI libraries to /usr/local/lib/swarm-cloud/dist/libs";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'mkdir -p /usr/local/lib/swarm-cloud/dist/libs';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/libs/ui /usr/local/lib/swarm-cloud/dist/libs/ui || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/libs/ui-utils /usr/local/lib/swarm-cloud/dist/libs/ui-utils || true';

    log_info "copying workspace-level Node.js dependencies and configs to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/node_modules /usr/local/lib/swarm-cloud/node_modules || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/package.json /usr/local/lib/swarm-cloud/package.json';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/pnpm-lock.yaml /usr/local/lib/swarm-cloud/pnpm-lock.yaml || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/pnpm-workspace.yaml /usr/local/lib/swarm-cloud/pnpm-workspace.yaml || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'mkdir -p /usr/local/lib/swarm-cloud/dist';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/tsconfig.base.json /usr/local/lib/swarm-cloud/dist/tsconfig.base.json || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp /opt/swarm-cloud/tsconfig.json /usr/local/lib/swarm-cloud/dist/tsconfig.json || true';

    log_info "removing sources from /opt/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'rm -rf /opt/swarm-cloud || true';
}

chroot_init;
build_swarm_cloud;
chroot_deinit;
