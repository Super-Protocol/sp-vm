#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function setup_runtime_tools() {
    log_info "creating policy-rc.d to prevent daemon autostart in chroot"
    printf '#!/bin/sh\nexit 101\n' > "${OUTPUTDIR}/usr/sbin/policy-rc.d"
    chmod +x "${OUTPUTDIR}/usr/sbin/policy-rc.d"

    log_info "installing runtime packages into rootfs (python3, redis, mysql client, openssl)"
    chroot "${OUTPUTDIR}" /usr/bin/apt update
    chroot "${OUTPUTDIR}" /usr/bin/apt install -y --no-install-recommends mysql-client python3 python3-pip redis-server redis-tools openssl
    chroot "${OUTPUTDIR}" /usr/bin/apt clean

    log_info "installing Python runtime dependencies"
    chroot "${OUTPUTDIR}" /bin/bash -lc 'python3 -m pip install --break-system-packages SQLAlchemy PyMySQL requests'

    log_info "ensuring redis data/log directories exist with proper ownership"
    chroot "${OUTPUTDIR}" /bin/bash -lc 'mkdir -p /var/lib/redis /var/log/redis && chown -R redis:redis /var/lib/redis /var/log/redis && chmod 0750 /var/lib/redis'
}

chroot_init
setup_runtime_tools
chroot_deinit
