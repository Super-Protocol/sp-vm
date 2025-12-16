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

    # swarm-cloud-api
    log_info "building swarm-cloud-api";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/swarm-cloud && pnpm nx build swarm-cloud-api --skip-nx-cache --output-style=stream --verbose';

    log_info "publishing built swarm-cloud-api artifacts to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'set -e; mkdir -p /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-cloud-api/dist/* /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-api/';

    # swarm-node
    log_info "building swarm-node";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/swarm-cloud && pnpm nx build swarm-node --skip-nx-cache --output-style=stream --verbose';

    log_info "publishing built swarm-node artifacts to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'set -e; mkdir -p /usr/local/lib/swarm-cloud/dist/apps/swarm-node';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/apps/swarm-node/dist/* /usr/local/lib/swarm-cloud/dist/apps/swarm-node/';

    # swarm-cloud-ui
    log_info "building swarm-cloud-ui";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/swarm-cloud && pnpm nx build swarm-cloud-ui --skip-nx-cache --output-style=stream --verbose';

    log_info "deploying swarm-cloud-ui via pnpm deploy to /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui";
    chroot "${OUTPUTDIR}" /bin/bash -lc '\
set -e; \
rm -rf /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui || true; \
mkdir -p /usr/local/lib/swarm-cloud/dist/apps; \
cd /opt/swarm-cloud && pnpm --filter @swarm-cloud/swarm-cloud-ui deploy --legacy /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui \
';

    log_info "copying shared UI libraries to /usr/local/lib/swarm-cloud/dist/libs";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'mkdir -p /usr/local/lib/swarm-cloud/dist/libs';
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -r /opt/swarm-cloud/libs/ui /usr/local/lib/swarm-cloud/dist/libs/ui';

    # In the deployed UI lib, TypeScript sources live under libs/ui/src, but some imports
    # reference sibling TS modules with a .js extension (e.g. "../lib/utils.js", "./button.js").
    # Next + TS expect extension-less imports for TS modules. Adjust imports only in the
    # deployed copy (do not touch the original sources under src/repos).
    chroot "${OUTPUTDIR}" /bin/bash -lc "\
find /usr/local/lib/swarm-cloud/dist/libs/ui/src -type f \\( -name '*.ts' -o -name '*.tsx' \\) -print0 \
  | xargs -0 sed -i 's/\\.js\\([\"'\"'\"']\\)/\\1/g'"

    log_info "copying workspace-level Node.js dependencies and configs to /usr/local/lib/swarm-cloud";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'mkdir -p /usr/local/lib/swarm-cloud/node_modules';
    # copy the *contents* of node_modules so that the .pnpm layout and symlink targets remain valid
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cp -a /opt/swarm-cloud/node_modules/. /usr/local/lib/swarm-cloud/node_modules/';
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
