#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR
# RKE2_INSTALL_SHA256

# private
BUILDROOT="/buildroot";

# init logging;
source "$BUILDROOT/files/scripts/log.sh";

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh";

function install_rke2() {
    log_info "staging rke2 installer into rootfs"
    mkdir -p "$OUTPUTDIR/root/rke2";
    wget -q -O "$OUTPUTDIR/root/rke2/rke2-install.sh" "https://get.rke2.io";

    log_info "verifying rke2 installer sha256"
    echo "${RKE2_INSTALL_SHA256}  $OUTPUTDIR/root/rke2/rke2-install.sh" | sha256sum -c -;

    log_info "installing rke2"
    chroot "$OUTPUTDIR" /bin/bash -c 'bash /root/rke2/rke2-install.sh';
    rm -rf "$OUTPUTDIR/root/rke2";
}

function disable_rke2_service() {
    log_info "disabling rke2 services"
    chroot "$OUTPUTDIR" /bin/bash -c 'systemctl disable rke2-server.service || true';
    chroot "$OUTPUTDIR" /bin/bash -c 'systemctl disable rke2-agent.service || true';
}

function add_aliases() {
    log_info "adding kubectl aliases"
    echo "export KUBECONFIG=/var/lib/rancher/rke2/rke2.yaml" >> "$OUTPUTDIR/etc/profile";
    echo "alias k='/var/lib/rancher/rke2/bin/kubectl'" >> "$OUTPUTDIR/etc/profile";
    echo "alias kubectl='/var/lib/rancher/rke2/bin/kubectl'" >> "$OUTPUTDIR/etc/profile";
}

chroot_init;
install_rke2;
disable_rke2_service;
chroot_deinit;
add_aliases;
