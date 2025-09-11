#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh";

function install_rke2() {
    log_info "installing rke2";
    chroot "$OUTPUTDIR" /bin/bash -c 'INSTALL_RKE2_ARTIFACT_PATH=/root/rke2 bash /root/rke2/rke2-install.sh';
    rm -rf "$OUTPUTDIR/root/rke2";
}

function enable_rke2_service() {
    log_info "installing rke2";
    chroot "$OUTPUTDIR" /bin/bash -c 'systemctl enable rke2-server.service';
}

function add_aliases() {
    log_info "adding aliases";
    echo "export KUBECONFIG=/var/lib/rancher/rke2/rke2.yaml" >> "$OUTPUTDIR/etc/profile";
    echo "alias k='/var/lib/rancher/rke2/bin/kubectl'" >> "$OUTPUTDIR/etc/profile";
    echo "alias kubectl='/var/lib/rancher/rke2/bin/kubectl'" >> "$OUTPUTDIR/etc/profile";
}

chroot_init;
install_rke2;
enable_rke2_service;
chroot_deinit;
add_aliases;
