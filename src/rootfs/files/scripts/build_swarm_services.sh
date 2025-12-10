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

function build_swarm_services() {
    local workspaces=(
        "apps/api-gateway"
        "apps/workload-service"
        "apps/blockchain-observer-service"
        "apps/tee-entry-certificates-service"
        "apps/content-certificates-service"
        "apps/version-certificates-service"
        "apps/resource-certificates-service"
        "packages/blockchain"
        "packages/common"
        "packages/config"
        "packages/content-certificates-client"
        "packages/dto"
        "packages/metrics"
        "packages/nest-jetstream"
        "packages/resource-certificates-client"
        "packages/tee-entry-certificates-client"
        "packages/utils"
        "packages/version-certificates-client"
    );

    local target="/usr/local/lib/sp-swarm-services";

    log_info "installing Node.js dependencies with npm ci";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/sp-swarm-services && npm ci --no-fund --no-audit --no-progress --loglevel=error -a';

    log_info "building all workspaces";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/sp-swarm-services && npm run build -a';

    log_info "preparing ${target}";
    chroot "${OUTPUTDIR}" /bin/bash -lc "set -e; rm -rf ${target}; mkdir -p ${target}/apps";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp /opt/sp-swarm-services/package.json ${target}/package.json";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp /opt/sp-swarm-services/package-lock.json ${target}/package-lock.json";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp /opt/sp-swarm-services/env.example ${target}/env.example || true";

    for workspace in "${workspaces[@]}"; do
        log_info "copying service ${workspace}";
        chroot "${OUTPUTDIR}" /bin/bash -lc "set -e; \
            src=/opt/sp-swarm-services/${workspace}; \
            dst=${target}/${workspace}; \
            mkdir -p \"\$dst\"; \
            cp \"\$src/package.json\" \"\$dst/\"; \
            [ -f \"\$src/configuration.example.yaml\" ] && cp \"\$src/configuration.example.yaml\" \"\$dst/\"; \
            [ -d \"\$src/dist\" ] && cp -fR \"\$src/dist\" \"\$dst/\"";
    done

    log_info "removing sources from /opt/sp-swarm-services";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'rm -rf /opt/sp-swarm-services || true';
    chroot "${OUTPUTDIR}" /bin/bash -lc "cd ${target} && npm ci --omit=dev --no-fund --no-audit --no-progress --loglevel=error"
}

chroot_init;
build_swarm_services;
chroot_deinit;
