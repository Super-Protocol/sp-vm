#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
readonly NVIDIA_DRIVER_VERSION="595.91.07";
readonly NVIDIA_DRIVER_DEB_VERSION="${NVIDIA_DRIVER_VERSION}-1ubuntu1";
readonly NVLINK5_DEB_VERSION="${NVIDIA_DRIVER_VERSION}-1";
readonly COLLECTX_BRINGUP_DEB_VERSION="1.22.1-1";
readonly MFT_DEB_VERSION="4.35.0.159-1";
readonly NVLSM_DEB_VERSION="2025.10.14-1";

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
    local kernel_release;
    kernel_release="$(<"$BUILDROOT/kernel-release")";

    log_info "installing NVIDIA R595 driver, NVLink 5 stack, RDMA userspace, and container toolkit for rke2";
    chroot \
        "$OUTPUTDIR" \
        /usr/bin/env \
        NVIDIA_DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" \
        NVIDIA_DRIVER_DEB_VERSION="$NVIDIA_DRIVER_DEB_VERSION" \
        NVLINK5_DEB_VERSION="$NVLINK5_DEB_VERSION" \
        COLLECTX_BRINGUP_DEB_VERSION="$COLLECTX_BRINGUP_DEB_VERSION" \
        MFT_DEB_VERSION="$MFT_DEB_VERSION" \
        NVLSM_DEB_VERSION="$NVLSM_DEB_VERSION" \
        KERNEL_RELEASE="$kernel_release" \
        /bin/bash \
        -c '
            set -eE;
            export DEBIAN_FRONTEND=noninteractive;

            dump_dkms_logs() {
                echo "===== DKMS build logs =====" >&2;
                find /var/lib/dkms \
                    -path "*/build/make.log" \
                    -type f \
                    -print \
                    -exec tail -n 250 {} \; \
                    >&2 \
                    || true;
            }
            trap dump_dkms_logs ERR;

            apt-get update;
            apt-get install -y --no-install-recommends \
                "nvidia-driver-pinning-${NVIDIA_DRIVER_VERSION}=${NVIDIA_DRIVER_DEB_VERSION}";

            # Starting with R590, NVIDIA driver package names no longer carry a
            # branch suffix. The official version-lock package pins the driver,
            # open modules, GSP firmware, NVML/userspace, Fabric Manager, NSCQ,
            # NVSDM, IMEX, and nvlink5 to NVIDIA_DRIVER_VERSION.
            #
            # Pin the unbranched nvlink5 companion packages explicitly as well;
            # their versions identify the set shipped with R595.91.07, rather
            # than carrying the driver version in every package name.
            # The guest kernel provides its in-tree mlx5 and InfiniBand
            # modules. Do not install the doca-ofed meta-package here: it
            # replaces them with a complete MOFED DKMS stack and also pulls
            # unrelated xpmem/iSER/SRP modules. The userspace packages below
            # are sufficient for NVLSM and provide ucx, which is a hard
            # dependency of collectx-bringup from nvlink5.
            apt-get install -y --no-install-recommends \
                infiniband-diags \
                libibumad3 \
                "collectx-bringup=${COLLECTX_BRINGUP_DEB_VERSION}" \
                "mft=${MFT_DEB_VERSION}" \
                "mft-autocomplete=${MFT_DEB_VERSION}" \
                "mft-oem=${MFT_DEB_VERSION}" \
                "nvidia-open=${NVIDIA_DRIVER_DEB_VERSION}" \
                "nvlink5=${NVLINK5_DEB_VERSION}" \
                "nvlsm=${NVLSM_DEB_VERSION}" \
                nvidia-container-toolkit \
                pciutils \
                rdma-core \
                ucx;

            driver_stack_packages=(
                libnvidia-cfg1
                libnvidia-compute
                libnvidia-decode
                libnvidia-encode
                libnvidia-fbc1
                libnvidia-gl
                libnvidia-nscq
                libnvsdm
                nvidia-dkms-open
                nvidia-driver-open
                nvidia-fabricmanager
                nvidia-firmware
                nvidia-imex
                nvidia-kernel-common
                nvidia-kernel-source-open
                nvidia-modprobe
                nvidia-open
                nvidia-persistenced
                nvlink5
                xserver-xorg-video-nvidia
            );
            for package in "${driver_stack_packages[@]}"; do
                installed_version="$(dpkg-query -W -f="\${Version}" "$package")";
                case "$installed_version" in
                    "${NVIDIA_DRIVER_VERSION}"-*) ;;
                    *)
                        echo "Unexpected $package version: $installed_version" >&2;
                        exit 1;
                        ;;
                esac;
            done;

            if dpkg-query -W -f="\${binary:Package}\t\${Version}\n" \
                | grep -E "[[:space:]]590[.]"; then
                echo "R590 package leftovers detected" >&2;
                exit 1;
            fi;

            dkms status "nvidia/${NVIDIA_DRIVER_VERSION}" -k "$KERNEL_RELEASE" \
                | grep -q "installed";
            for module in nvidia nvidia_uvm nvidia_modeset; do
                test "$(modinfo -k "$KERNEL_RELEASE" -F version "$module")" \
                    = "$NVIDIA_DRIVER_VERSION";
            done;
        ';

    # NVLSM communicates with the NVLink-management CX7 ports through UMAD.
    # Loading ib_umad is harmless on systems without InfiniBand hardware and
    # makes the generic image ready before Fabric Manager's boot-time probe.
    install -d "$OUTPUTDIR/etc/modules-load.d";
    printf '%s\n' 'ib_umad' > "$OUTPUTDIR/etc/modules-load.d/ib_umad.conf";
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
