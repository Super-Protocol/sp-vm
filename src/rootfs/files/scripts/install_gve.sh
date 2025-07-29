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

function install_gve_dkms() {
    log_info "downloading gve dkms";
    wget \
        "https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-linux/releases/download/v1.4.5.1/gve-dkms_1.4.5.1_all.deb" \
        -O "$OUTPUTDIR/tmp/gve-dkms_1.4.5.1_all.deb";

    log_info "installing gve dkms";
    chroot "$OUTPUTDIR" /bin/bash -c 'apt install ./tmp/gve-dkms_1.4.5.1_all.deb';
    echo "gve" > "$OUTPUTDIR/etc/modules-load.d/gve.conf";
    chroot "$OUTPUTDIR" /bin/bash -c 'depmod 6.12.13-nvidia-gpu-confidential';
    rm "$OUTPUTDIR/tmp/gve-dkms_1.4.5.1_all.deb";
}

chroot_init;
install_gve_dkms;
chroot_deinit;
