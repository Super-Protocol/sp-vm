#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_python_deps() {
    log_info "installing Python dependencies for provision plugins"
    # redis-py is already installed by setup_runtime_tools.sh, but ensure correct version range
    # (setup_runtime_tools.sh installs latest; provision plugins require >=5.0.0,<6.0.0)
    chroot "$OUTPUTDIR" /bin/bash -lc "pip3 install --break-system-packages 'redis>=5.0.0,<6.0.0'"
    # podman-compose: required for provision plugins that orchestrate Podman containers
    chroot "$OUTPUTDIR" /bin/bash -lc "pip3 install --break-system-packages podman-compose"
    # pyyaml: required by swarm-init.sh to parse /etc/swarm/config.yaml at runtime
    chroot "$OUTPUTDIR" /bin/bash -lc "pip3 install --break-system-packages pyyaml"
    log_info "Python dependencies installed successfully"
}

chroot_init
install_python_deps
chroot_deinit
