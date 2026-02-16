#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# public, optional
# $1 - PKI_SYNC_CLIENT_VERSION - version to install, if not set - installs latest

# private
BUILDROOT="/buildroot";

# init loggggging;
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

function install_sync_client() {
    local PKI_SYNC_CLIENT_VERSION="${1:-}";
    local PACKAGE_NAME="@super-protocol/pki-sync-client";
    local PACKAGE_SPEC="${PACKAGE_NAME}";
    
    if [ -n "${PKI_SYNC_CLIENT_VERSION}" ]; then
        PACKAGE_SPEC="${PACKAGE_NAME}@${PKI_SYNC_CLIENT_VERSION}";
        log_info "installing ${PACKAGE_SPEC} npm package globally";
    else
        PACKAGE_SPEC="${PACKAGE_NAME}@latest";
        log_info "installing ${PACKAGE_SPEC} npm package globally";
    fi
    
    chroot "${OUTPUTDIR}" /bin/bash -c "npm install -g ${PACKAGE_SPEC}";
    log_info "${PACKAGE_SPEC} installed successfully";
}

chroot_init;
install_sync_client "${1:-}";
chroot_deinit;
