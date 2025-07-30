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

function setup_hauler() {
    log_info "setting hauler up";
    pushd "$OUTPUTDIR/opt/hauler";
    cp "$BUILDROOT/files/configs/hauler/rke2-airgap.yaml" "$OUTPUTDIR/root/rke2-airgap.yaml";
    chroot "$OUTPUTDIR" /bin/bash -c 'pushd /opt/hauler && hauler store sync --store rke2-store --platform linux/amd64 --files /root/rke2-airgap.yaml && popd';
    rm "$OUTPUTDIR/root/rke2-airgap.yaml";
    chroot "$OUTPUTDIR" /bin/bash -c 'pushd /opt/hauler && hauler store add --store rke2-store image ghcr.io/super-protocol/tee-pki-curl:v1.5.1 --platform linux/amd64 && popd';
    chroot "$OUTPUTDIR" /bin/bash -c 'pushd /opt/hauler && hauler store save --store rke2-store --filename rke2-airgap.tar.zst && popd';
    # TODO: add argo-cd, argo-workflows, cert-manager, gpu-operator, longhorn charts

    mkdir -p "$OUTPUTDIR/etc/super/opt/hauler";
    cp *.tar.zst "$OUTPUTDIR/etc/super/opt/hauler/";
    rm -rf "$OUTPUTDIR/opt/hauler";

    popd;
}

chroot_init;
setup_hauler;
chroot_deinit;
