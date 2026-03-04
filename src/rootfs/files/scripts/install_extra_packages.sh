#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_extra_packages() {
    log_info "installing extra system packages for cloud-init compatibility"

    chroot "$OUTPUTDIR" /bin/bash -lc "apt-get update"

    # podman: container runtime used by cloud-init-style swarm services
    #         (cloud-init runs swarm-node as a Podman container; also needed by provision plugins)
    # unzip: used to extract service archives (download-services.sh)
    # NOTE: mysql-client, netcat-openbsd, dnsutils are already installed by setup_runtime_tools.sh
    chroot "$OUTPUTDIR" /bin/bash -lc "apt-get install -y --no-install-recommends \
        podman \
        unzip"

    chroot "$OUTPUTDIR" /bin/bash -lc "apt-get clean"
    log_info "extra packages installed successfully"
}

chroot_init
install_extra_packages
chroot_deinit
