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
    local services=(
        "@apps/api-gateway"
        "@apps/workload-service"
        "@apps/blockchain-observer-service"
        "@apps/tee-entry-certificates-service"
        "@apps/content-certificates-service"
        "@apps/version-certificates-service"
        "@apps/resource-certificates-service"
    );

    local target="/usr/local/lib/sp-swarm-services";

    log_info "installing Node.js dependencies with npm ci";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/sp-swarm-services && npm ci -a';

    log_info "building all workspaces";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'cd /opt/sp-swarm-services && npm run build -a';

    log_info "preparing ${target}";
    chroot "${OUTPUTDIR}" /bin/bash -lc "set -e; rm -rf ${target}; mkdir -p ${target}/apps";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp /opt/sp-swarm-services/package.json ${target}/package.json";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp /opt/sp-swarm-services/package-lock.json ${target}/package-lock.json";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp /opt/sp-swarm-services/env.example ${target}/env.example || true";
    chroot "${OUTPUTDIR}" /bin/bash -lc "cp -a /opt/sp-swarm-services/node_modules ${target}/node_modules";

    for service in "${services[@]}"; do
        local dir_name="${service#@apps/}";
        log_info "copying service ${service}";
        chroot "${OUTPUTDIR}" /bin/bash -lc "set -e; src=/opt/sp-swarm-services/apps/${dir_name}; dst=${target}/apps/${dir_name}; mkdir -p \"\$dst\"; cp \"\$src/package.json\" \"\$dst/\"; [ -f \"\$src/configuration.example.yaml\" ] && cp \"\$src/configuration.example.yaml\" \"\$dst/\"; [ -d \"\$src/dist\" ] && cp -r \"\$src/dist\" \"\$dst/\"";
    done

    log_info "removing sources from /opt/sp-swarm-services";
    chroot "${OUTPUTDIR}" /bin/bash -lc 'rm -rf /opt/sp-swarm-services || true';
}

chroot_init;
build_swarm_services;
chroot_deinit;
