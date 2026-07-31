#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
GVE_VERSION="1.4.5.1";
GVE_DEB_SHA256="a75b5ab7a3c4a1b6a23f18a74ac9fe86a8759598948843ec4afda5a80e99ccea";
GVE_DEB="gve-dkms_${GVE_VERSION}_all.deb";
GVE_DEB_PATH="${OUTPUTDIR}/tmp/${GVE_DEB}";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh";

function install_gve_dkms() {
    log_info "downloading gve dkms";
    wget --https-only \
        "https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-linux/releases/download/v${GVE_VERSION}/${GVE_DEB}" \
        -O "$GVE_DEB_PATH";
    printf '%s  %s\n' "$GVE_DEB_SHA256" "$GVE_DEB_PATH" \
        | sha256sum --check --strict -;

    log_info "installing gve dkms";
    chroot "$OUTPUTDIR" apt-get install -y --no-install-recommends "/tmp/${GVE_DEB}";
    echo "gve" > "$OUTPUTDIR/etc/modules-load.d/gve.conf";

    KERNEL_RELEASE="$(< "$BUILDROOT/kernel-release")";
    log_info "running depmod for $KERNEL_RELEASE";
    chroot "$OUTPUTDIR" depmod "$KERNEL_RELEASE";
    rm -f "$GVE_DEB_PATH";
}

chroot_init;
install_gve_dkms;
chroot_deinit;
