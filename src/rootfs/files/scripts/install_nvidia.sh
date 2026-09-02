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

function install_doca_repository() {
    local repo_url="https://linux.mellanox.com/public/repo/doca/3.2.1-044418/ubuntu24.04/x86_64";

    log_info "configuring NVIDIA DOCA 3.2.1 repository";
    install -d \
        "$OUTPUTDIR/usr/share/keyrings" \
        "$OUTPUTDIR/etc/apt/sources.list.d";
    wget \
        "https://linux.mellanox.com/public/repo/doca/public_keys/nvidia-doca-debian-gpg-public-key.gpg" \
        -O "$OUTPUTDIR/usr/share/keyrings/nvidia-doca.gpg";
    printf '%s\n' \
        'Types: deb' \
        "URIs: $repo_url" \
        'Suites: /' \
        'Signed-By: /usr/share/keyrings/nvidia-doca.gpg' \
        > "$OUTPUTDIR/etc/apt/sources.list.d/nvidia-doca.sources";
}

function install_nvidia_driver() {
    log_info "installing NVIDIA R590 driver, DOCA-OFED, NVLink 5 stack, and container toolkit for rke2";
    chroot \
        "$OUTPUTDIR" \
        /bin/bash \
        -c '
            set -e;
            export DEBIAN_FRONTEND=noninteractive;

            apt-get update;
            apt-get install -y --no-install-recommends nvidia-driver-pinning-590.48.01;

            # Starting with R590, NVIDIA driver package names no longer carry
            # the branch suffix. nvlink5 installs the matching Fabric Manager,
            # NVLSM, NVSDM, NSCQ, IMEX, and MFT components required by B200.
            # DOCA-OFED provides the matching RDMA stack and the ucx package
            # required by collectx-bringup, a hard dependency of nvlink5.
            apt-get install -y --no-install-recommends \
                doca-ofed \
                nvidia-open \
                nvlink5 \
                nvidia-container-toolkit;
        ';
}

function create_containerd_symlink() {
    log_info "creating containerd symlink";
    # TODO(SP-7710): Temporary workaround; the underlying issue is described in SP-7710.
    chroot \
        "$OUTPUTDIR" \
        /bin/bash \
        -c 'ln -sf /var/lib/rancher/rke2/bin/containerd /usr/local/bin/containerd';
}

chroot_init;
install_cuda_keyring;
install_doca_repository;
install_nvidia_driver;
create_containerd_symlink;
chroot_deinit;
