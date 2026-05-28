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

    # Add CZ.NIC Knot DNS repository
    local knot_version="3.5.1"
    chroot "$OUTPUTDIR" /bin/bash -lc "curl -fsSL https://pkg.labs.nic.cz/gpg -o /usr/share/keyrings/cznic-labs-pkg.gpg"
    chroot "$OUTPUTDIR" /bin/bash -lc "echo 'deb [signed-by=/usr/share/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/knot-dns noble main' > /etc/apt/sources.list.d/cznic-labs-knot-dns.list"
    chroot "$OUTPUTDIR" /bin/bash -lc "printf 'Package: knot knot-* libdnssec* libzscanner* libknot* python3-libknot*\nPin-Priority: 1001\nPin: version ${knot_version}*\n' > /etc/apt/preferences.d/knot"

    chroot "$OUTPUTDIR" /bin/bash -lc "apt-get update"

    # unzip: used to extract service archives (download-services.sh)
    # wireguard-tools: required by the wireguard provision service (wireguard kernel module is in BASE_PACKAGES)
    # redis-tools: redis-cli required by the redis and redis-sentinel provision services
    # nats-server: required by the nats provision service
    # knot: Knot DNS server required by the knot provision service (pinned via apt preferences)
    # wget: required by the openresty provision service to download nginx config
    # NOTE: mysql-client, netcat-openbsd, dnsutils are already installed by setup_runtime_tools.sh
    chroot "$OUTPUTDIR" /bin/bash -lc "apt-get install -y \
        podman \
        unzip \
        wireguard-tools \
        redis-tools \
        nats-server \
        wget \
        jq \
        'knot=${knot_version}*'"

    # apt installs 87-podman-bridge.conflist into /etc/cni/net.d; move it for kubelet isolation.
    chroot "$OUTPUTDIR" /usr/local/bin/configure-podman-cni.sh

    chroot "$OUTPUTDIR" /bin/bash -lc "apt-get clean"
    log_info "extra packages installed successfully"
}

chroot_init
install_extra_packages
chroot_deinit
