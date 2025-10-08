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

function install_cuda_keyring() {
    log_info "downloading cuda keyring";
    wget \
        "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb" \
        -O "$OUTPUTDIR/tmp/cuda-keyring_1.1-1_all.deb";

    log_info "installing cuda keyring";
    chroot "$OUTPUTDIR" /bin/bash -c '/usr/bin/dpkg -i /tmp/cuda-keyring_1.1-1_all.deb';
    rm "$OUTPUTDIR/tmp/cuda-keyring_1.1-1_all.deb";
}

function install_nvidia_driver() {
    log_info "installing nvidia driver";
    chroot \
        "$OUTPUTDIR" \
        /bin/bash \
        -c 'DEBIAN_FRONTEND=noninteractive apt update && apt install -y --no-install-recommends nvidia-driver-575-open';
}

chroot_init;
install_cuda_keyring;
install_nvidia_driver;
chroot_deinit;
