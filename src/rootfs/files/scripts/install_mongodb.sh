#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_mongodb() {
    log_info "installing MongoDB (mongodb-org 7.0) inside VM rootfs"
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt update'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt install -y --no-install-recommends gnupg curl'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt update'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt install -y --no-install-recommends mongodb-org mongodb-mongosh'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt clean'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; mkdir -p /var/lib/mongodb /var/log/mongodb'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb || true'
}

chroot_init
install_mongodb
chroot_deinit


