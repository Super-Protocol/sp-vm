#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_nats() {
    local NATS_VERSION="2.12.2"
    local NATS_PKG="nats-server-v${NATS_VERSION}-linux-amd64"
    local NATS_URL="https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/${NATS_PKG}.tar.gz"

    log_info "installing NATS (nats-server v${NATS_VERSION}) inside VM rootfs"

    # prerequisites
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt update'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt install -y --no-install-recommends curl ca-certificates tar'

    # download and install binary
    chroot "$OUTPUTDIR" /bin/bash -lc "set -e; cd /tmp && curl -fsSL '${NATS_URL}' -o ${NATS_PKG}.tar.gz"
    chroot "$OUTPUTDIR" /bin/bash -lc "set -e; cd /tmp && tar -xzf ${NATS_PKG}.tar.gz"
    chroot "$OUTPUTDIR" /bin/bash -lc "set -e; install -m 0755 /tmp/${NATS_PKG}/nats-server /usr/local/bin/nats-server"

    # create user/group if absent
    chroot "$OUTPUTDIR" /bin/bash -lc "getent group nats >/dev/null 2>&1 || groupadd --system nats"
    chroot "$OUTPUTDIR" /bin/bash -lc "id -u nats >/dev/null 2>&1 || useradd --system --no-create-home --gid nats nats"

    # directories
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; mkdir -p /etc/nats /var/lib/nats /var/log/nats'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; chown -R nats:nats /etc/nats /var/lib/nats /var/log/nats || true'

    # systemd unit
    cat > "${OUTPUTDIR}/usr/lib/systemd/system/nats-server.service" <<'UNIT'
[Unit]
Description=NATS Server
After=network-online.target
Wants=network-online.target

[Service]
User=nats
Group=nats
ExecStart=/usr/local/bin/nats-server -c /etc/nats/nats-server.conf
Restart=always
RestartSec=2
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
UNIT

    # cleanup
    chroot "$OUTPUTDIR" /bin/bash -lc "rm -rf /tmp/${NATS_PKG} /tmp/${NATS_PKG}.tar.gz"
    chroot "$OUTPUTDIR" /bin/bash -lc 'apt clean'
}

chroot_init
install_nats
chroot_deinit
