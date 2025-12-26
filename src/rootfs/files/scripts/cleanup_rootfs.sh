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
    # best-effort removal of heavy toolchain packages only; keep core dev libs (libc6-dev, linux-libc-dev, etc.)
    # so that OpenResty and other components depending on them continue to work.
    chroot "$OUTPUTDIR" /bin/bash -c \
        'dpkg -r \
            build-essential \
            g++-13 \
            g++-13-x86-64-linux-gnu \
            g++-x86-64-linux-gnu \
            linux-headers-6.12.13-nvidia-gpu-confidential \
            g++ \
            gcc';
    rm -rf ${OUTPUTDIR}/tmp/*;
    rm -rf ${OUTPUTDIR}/usr/share/{bash-completion,bug,doc,info,lintian,locale,man,menu,misc,pixmaps,terminfo,zsh};
    find "${OUTPUTDIR}/var/run" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; || true;
    rm -rf ${OUTPUTDIR}/var/{cache,lib,log,tmp};
    rm -f "${OUTPUTDIR}/etc/systemd/system/sshd.service"
    rm -f "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/ssh.service"
    rm -f "${OUTPUTDIR}/etc/systemd/system/sockets.target.wants/ssh.socket"
    rm -f "${OUTPUTDIR}/etc/systemd/system/ssh.service.requires/ssh.socket"
    rm -f "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
}

chroot_init;
cleanup_rootfs;
chroot_deinit;
