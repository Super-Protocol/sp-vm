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

function cleanup_rootfs() {
    log_info "cleaning up rootfs";
    rm -rf "${OUTPUTDIR}/kernel_deb";
    chroot "$OUTPUTDIR" /bin/bash -c \
        'dpkg -r \
            libc6-dev \
            linux-libc-dev \
            libstdc++-13-dev \
            build-essential \
            gcc-13 \
            g++-13 \
            g++-13-x86-64-linux-gnu \
            g++-x86-64-linux-gnu \
            linux-headers-6.12.13-nvidia-gpu-confidential \
            g++ \
            gcc';
    rm -rf ${OUTPUTDIR}/tmp/*;
    rm -rf ${OUTPUTDIR}/usr/share/{bash-completion,bug,doc,info,lintian,locale,man,menu,misc,pixmaps,terminfo,zsh};
    rm -rf "${OUTPUTDIR}/var/run";
    rm -rf ${OUTPUTDIR}/var/{cache,lib,log,tmp};
    # debug
    chroot "$OUTPUTDIR" usermod -p '$6$WD6M1MokAy0ZAjG4$bUVCV5BQlmJm4QaL8XOeBV7QC7BpLmNAr7glIDVSBAgMPv2eHNWmIw86zTFhlBCXDOV.O1az.zrbx0G0FVdSV/' root;
}

chroot_init;
cleanup_rootfs;
chroot_deinit;
