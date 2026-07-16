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
    log_info "installing Python runtime dependencies"
    cp "$BUILDROOT/files/configs/python/requirements.lock" \
        "$OUTPUTDIR/tmp/python-requirements.lock"
    chroot "$OUTPUTDIR" python3 -m pip install \
        --break-system-packages \
        --disable-pip-version-check \
        --ignore-installed \
        --no-cache-dir \
        --no-compile \
        --only-binary=:all: \
        --require-hashes \
        --requirement /tmp/python-requirements.lock
    rm -f "${OUTPUTDIR}/tmp/python-requirements.lock"
    log_info "Python dependencies installed successfully"
}

chroot_init
install_python_deps
chroot_deinit
