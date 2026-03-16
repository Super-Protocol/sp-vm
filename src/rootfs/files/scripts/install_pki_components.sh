#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# public, optional
# $1 - PKI_SYNC_CLIENT_VERSION - version to install, if not set - installs latest
# $2 - PKI_CERT_GENERATOR_VERSION - version to install, if not set - installs latest

# private
BUILDROOT="/buildroot";

# init loggggging;
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

function install_npm_package() {
    local PACKAGE_NAME="${1}";
    local PACKAGE_VERSION="${2:-}";
    local PACKAGE_SPEC="${PACKAGE_NAME}";

    if [ -n "${PACKAGE_VERSION}" ]; then
        PACKAGE_SPEC="${PACKAGE_NAME}@${PACKAGE_VERSION}";
    else
        PACKAGE_SPEC="${PACKAGE_NAME}@latest";
    fi

    log_info "installing ${PACKAGE_SPEC} npm package globally";
    chroot "${OUTPUTDIR}" /bin/bash -c "npm install -g ${PACKAGE_SPEC}";
    log_info "${PACKAGE_SPEC} installed successfully";
}

chroot_init;
install_npm_package "@super-protocol/pki-sync-client" "${1:-}";
install_npm_package "@super-protocol/pki-cert-generator" "${2:-}";
chroot_deinit;