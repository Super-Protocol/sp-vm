#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init loggggging;
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

function install_nodejs() {
    log_info "adding NodeSource repository";
    chroot "${OUTPUTDIR}" /bin/bash -c 'curl -sL https://deb.nodesource.com/setup_22.x | bash -';
    
    log_info "installing Node.js";
    chroot "${OUTPUTDIR}" /bin/bash -c 'DEBIAN_FRONTEND=noninteractive apt install -y nodejs';
    
    # Verify installation
    local NODE_VERSION=$(chroot "${OUTPUTDIR}" /bin/bash -c 'node --version' 2>/dev/null || true);
    if [ -z "${NODE_VERSION}" ]; then
        log_fail "Node.js installation failed";
        return 1;
    fi
    
    log_info "Node.js ${NODE_VERSION} installed successfully";
}

chroot_init;
install_nodejs;
chroot_deinit;
