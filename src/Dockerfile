# syntax=docker/dockerfile:1-labs

### Start busybox ###
FROM ubuntu:24.04 AS busybox_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
ARG busybox_version=1_36_1
ADD https://github.com/mirror/busybox/archive/refs/tags/${busybox_version}.tar.gz /tmp/busybox-${busybox_version}.tar.gz
RUN tar -C /tmp -xvf/tmp/busybox-${busybox_version}.tar.gz
WORKDIR /tmp/busybox-${busybox_version}
ADD initramfs/files/busybox_config /tmp/busybox-${busybox_version}/.config
RUN make -j
RUN mkdir -p /initramfs-root/sbin
RUN cp /tmp/busybox-${busybox_version}/busybox /initramfs-root/sbin/busybox
### End busybox ###

### Start util_linux ###
FROM ubuntu:24.04 AS util_linux_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
ARG util_linux_version=2.41
ADD https://www.kernel.org/pub/linux/utils/util-linux/v${util_linux_version}/util-linux-${util_linux_version}.tar.gz /tmp/util-linux-${util_linux_version}.tar.gz
RUN tar -C /tmp -xvf/tmp/util-linux-${util_linux_version}.tar.gz
WORKDIR /tmp/util-linux-${util_linux_version}
RUN ./configure --disable-shared --enable-static --disable-liblastlog2 --without-tinfo --without-ncurses --disable-ipv6 --disable-pylibmount
RUN make -j blkid wipefs lsblk LDFLAGS="--static"
RUN strip blkid wipefs lsblk
RUN mkdir -p /initramfs-root/sbin
RUN cp /tmp/util-linux-${util_linux_version}/blkid /initramfs-root/sbin/blkid
RUN cp /tmp/util-linux-${util_linux_version}/wipefs /initramfs-root/sbin/wipefs
RUN cp /tmp/util-linux-${util_linux_version}/lsblk /initramfs-root/sbin/lsblk
### End util_linux ###

### Start lvm2 ###
FROM ubuntu:24.04 AS lvm2_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential git libblkid-dev libaio-dev uuid-dev pkg-config
ARG lvm2_repo=https://github.com/lvmteam/lvm2
ARG lvm2_version=v2_03_16
RUN git clone --depth 1 --branch "${lvm2_version}" "${lvm2_repo}" /tmp/lvm2
WORKDIR /tmp/build-root
RUN /tmp/lvm2/configure --enable-static_link --disable-selinux --prefix /initramfs-root
RUN make -j
RUN make install
### End lvm2 ###

### Start cryptsetup ###
FROM ubuntu:24.04 AS cryptsetup_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential git libblkid-dev libaio-dev autoconf automake autopoint libtool gettext libssl-dev zlib1g-dev libseccomp2 libseccomp-dev uuid-dev pkg-config libgcrypt20-dev libpopt-dev libjson-c-dev
COPY --from=lvm2_builder /initramfs-root /initramfs-root
COPY --from=lvm2_builder /tmp/build-root/libdm/libdevmapper.pc /usr/lib/pkgconfig/devmapper.pc
ARG cryptsetup_repo=https://gitlab.com/cryptsetup/cryptsetup
ARG cryptsetup_version=v2.5.0
RUN git clone --depth 1 --branch "${cryptsetup_version}" "${cryptsetup_repo}" /tmp/cryptsetup
WORKDIR /tmp/cryptsetup
RUN /tmp/cryptsetup/autogen.sh
WORKDIR /tmp/build-root
RUN CFLAGS="-I/initramfs-root/include" CXXFLAGS="-I/initramfs-root/include" LDFLAGS="-L/initramfs-root/lib" /tmp/cryptsetup/configure --enable-static --enable-static-cryptsetup --disable-udev --disable-external-tokens --disable-ssh-token --disable-asciidoc --prefix /initramfs-root
RUN make -j
RUN make install
RUN strip /initramfs-root/sbin/veritysetup.static
RUN strip /initramfs-root/sbin/cryptsetup.static
### End cryptsetup ###

### Start gen_init_cpio ###
FROM ubuntu:24.04 AS gen_init_cpio_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
RUN apt -y install git
RUN git clone --depth 1 --filter=blob:none --sparse https://github.com/torvalds/linux.git /tmp/linux
WORKDIR /tmp/linux
RUN git sparse-checkout add usr
WORKDIR /tmp/linux/usr
RUN make -j gen_init_cpio
RUN install gen_init_cpio /usr/sbin/
### End gen_init_cpio ###

### Start e2fsprogs ###
FROM ubuntu:24.04 AS e2fsprogs_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
ARG e2fsprogs_version=1.47.3
ADD https://github.com/tytso/e2fsprogs/archive/refs/tags/v${e2fsprogs_version}.tar.gz /tmp/e2fsprogs-${e2fsprogs_version}.tar.gz
RUN tar -C /tmp -xvf/tmp/e2fsprogs-${e2fsprogs_version}.tar.gz
WORKDIR /tmp/e2fsprogs-${e2fsprogs_version}
RUN ./configure CFLAGS='-g -O2 -static' LDFLAGS='-static'
RUN make -j
RUN mkdir -p /initramfs-root/sbin
RUN cp /tmp/e2fsprogs-${e2fsprogs_version}/misc/mke2fs /initramfs-root/sbin/mkfs.ext4
RUN strip /initramfs-root/sbin/mkfs.ext4
### End e2fsprogs ###

### Start initramfs ###
FROM gen_init_cpio_builder AS initramfs_builder
COPY --from=busybox_builder /initramfs-root/sbin/busybox /initramfs-root/sbin/
COPY --from=util_linux_builder /initramfs-root/sbin/blkid /initramfs-root/sbin/
COPY --from=util_linux_builder /initramfs-root/sbin/lsblk /initramfs-root/sbin/
COPY --from=util_linux_builder /initramfs-root/sbin/wipefs /initramfs-root/sbin/
COPY --from=cryptsetup_builder /initramfs-root/sbin/veritysetup.static /initramfs-root/sbin/
COPY --from=cryptsetup_builder /initramfs-root/sbin/cryptsetup.static /initramfs-root/sbin/
COPY --from=e2fsprogs_builder /initramfs-root/sbin/mkfs.ext4 /initramfs-root/sbin/
ADD initramfs/files/initramfs.list /initramfs-root/initramfs.list
ADD initramfs/files/init.sh /initramfs-root/sbin/init.sh
RUN gen_init_cpio /initramfs-root/initramfs.list | gzip -9 -n > /initramfs-root/initramfs.cpio.gz
### End  ###

### Start kernel ###
FROM ubuntu:24.04 AS kernel_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential curl libssl-dev bc elfutils libelf-dev bison flex cpio kmod rsync debhelper
ARG KERNEL_VERSION=6.12.13

WORKDIR /buildroot

ADD general/files/scripts/log.sh /buildroot/files/scripts/

ADD kernel/files/scripts/download_and_verify_kernel_src.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/download_and_verify_kernel_src.sh

ADD kernel/files/scripts/merge-configs.sh /buildroot/files/scripts/
ADD kernel/files/scripts/merge_config.sh /buildroot/files/scripts/
ADD kernel/files/configs /buildroot/files/configs
RUN /buildroot/files/scripts/merge-configs.sh

COPY --from=initramfs_builder /initramfs-root/initramfs.cpio.gz /buildroot/files/
ADD kernel/files/scripts/build-kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/build-kernel.sh
### End kernel ###


### Start rootfs ###
FROM ubuntu:noble-20250714 AS rootfs_builder
RUN apt update && apt install -y wget gcc make build-essential debootstrap petname gettext

ARG PROVIDER_CONFIG_DST=/sp
ARG VERSION_CODENAME=noble
ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

WORKDIR /buildroot

ADD general/files/scripts/log.sh /buildroot/files/scripts/

ADD rootfs/files/scripts/create_base_system.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/create_base_system.sh

COPY --from=kernel_builder /output/deb ${OUTPUTDIR}/kernel_deb
ADD rootfs/files/scripts/install_kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/install_kernel.sh

ADD general/files/scripts/chroot.sh /buildroot/files/scripts/
ADD rootfs/files/scripts/install_nvidia.sh /buildroot/files/scripts/
RUN --security=insecure /buildroot/files/scripts/install_nvidia.sh
ADD rootfs/files/scripts/install_gve.sh /buildroot/files/scripts/install_gve.sh
RUN --security=insecure /buildroot/files/scripts/install_gve.sh

# Install s3fs-fuse for provider_config S3 bucket mounting
RUN --security=insecure chroot ${OUTPUTDIR} apt-get install -y s3fs
# Allow user_allow_other so s3fs -o allow_other works for non-root processes
RUN echo 'user_allow_other' >> ${OUTPUTDIR}/etc/fuse.conf

RUN mkdir -p "${OUTPUTDIR}/etc/super/var/lib/rancher/rke2/server/manifests"
ADD rootfs/files/configs/etc/super/var/lib/rancher/rke2/server/manifests/k8s-swarm.yaml \
    ${OUTPUTDIR}/etc/super/var/lib/rancher/rke2/server/manifests/k8s-swarm.yaml
RUN mkdir -p "${OUTPUTDIR}/etc/super/var/lib/rancher/rke2/agent/etc/containerd"
ADD rootfs/files/configs/etc/super/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl \
    ${OUTPUTDIR}/etc/super/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl

ADD rootfs/files/configs/usr/local/bin/sync-varlib.sh ${OUTPUTDIR}/usr/local/bin/sync-varlib.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/sync-varlib.sh
ADD rootfs/files/configs/etc/systemd/system/sync-varlib.service \
    ${OUTPUTDIR}/etc/systemd/system/sync-varlib.service
RUN ln -sf /etc/systemd/system/sync-varlib.service \
    "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/sync-varlib.service"

RUN mkdir -p "${OUTPUTDIR}/etc/systemd/system/getty.target.wants"
RUN ln -sf "/lib/systemd/system/getty@.service" "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/getty@ttyS0.service"
# ensure system boots into multi-user.target instead of graphical.target
RUN ln -sf "/lib/systemd/system/multi-user.target" "${OUTPUTDIR}/etc/systemd/system/default.target"

RUN cp "${OUTPUTDIR}/usr/share/systemd/tmp.mount" "${OUTPUTDIR}/etc/systemd/system/tmp.mount";

ADD rootfs/files/configs/01-netplan.yaml ${OUTPUTDIR}/etc/netplan/
ADD rootfs/files/configs/fstab ${OUTPUTDIR}/etc/
ADD rootfs/files/configs/tdx-attest.conf ${OUTPUTDIR}/etc/

ADD rootfs/files/configs/chrony/chrony.conf ${OUTPUTDIR}/etc/chrony/
ADD rootfs/files/configs/chrony/chrony.service ${OUTPUTDIR}/lib/systemd/system/

# Temporary debug: Allow root login (disable PAM restriction)
# RUN sed -i '1 s|^.*$|-:root:ALL|' "${OUTPUTDIR}/etc/security/access.conf"
# RUN sed -i '1 s|^.*$|account required pam_access.so|' "${OUTPUTDIR}/etc/pam.d/login"
ADD rootfs/files/configs/nvidia-persistenced.service ${OUTPUTDIR}/usr/lib/systemd/system/

RUN echo "sp-$(petname)" > "${OUTPUTDIR}/etc/hostname"
ADD rootfs/files/configs/etc/sysctl.d/99-zzz-override_cilium.conf ${OUTPUTDIR}/etc/sysctl.d/99-zzz-override_cilium.conf
ADD rootfs/files/configs/etc/resolv.conf ${OUTPUTDIR}/etc/resolv.conf
RUN mkdir -p "${OUTPUTDIR}/etc/rancher/rke2"
ADD rootfs/files/configs/etc/rancher/rke2/config.yaml ${OUTPUTDIR}/etc/rancher/rke2/config.yaml

# copy iscsi configs, cause this partition will be remounted with empty dir
RUN mkdir -p "${OUTPUTDIR}/etc/iscsi"
RUN cp -r "${OUTPUTDIR}/etc/iscsi/" "${OUTPUTDIR}/etc/super/etc/";
ADD rootfs/files/scripts/setup_sshd_config.sh /buildroot/files/scripts/setup_sshd_config.sh
RUN /buildroot/files/scripts/setup_sshd_config.sh

RUN mkdir -p "${OUTPUTDIR}/usr/local/bin";

# copy pki-authority service files
ADD rootfs/files/scripts/install_lxc_deps.sh /buildroot/files/scripts/
ADD rootfs/files/configs/pki-service/pki-authority.service "${OUTPUTDIR}/etc/systemd/system"
RUN ln -s /etc/systemd/system/pki-authority.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pki-authority.service"
ADD rootfs/files/configs/pki-service/create-and-configure-pki.sh "${OUTPUTDIR}/usr/local/bin"
RUN mkdir -p "${OUTPUTDIR}/root/containers"
COPY --from=ghcr.io/super-protocol/tee-pki-authority-service-lxc:build-18725490828 /pki-authority.tar "${OUTPUTDIR}/root/containers/pki-authority.tar"
ADD rootfs/files/configs/pki-service/lxc-template.yaml "${OUTPUTDIR}/root/containers/lxc-template.yaml"
ADD rootfs/files/configs/pki-service/dnsmasq.conf "${OUTPUTDIR}/etc/lxc/dnsmasq.conf"
ADD rootfs/files/configs/pki-service/lxc-net "${OUTPUTDIR}/etc/default/lxc-net"
RUN --security=insecure /buildroot/files/scripts/install_lxc_deps.sh

ADD rootfs/files/configs/etc/multipath.conf.append /buildroot/files/configs/etc/multipath.conf.append
ADD rootfs/files/configs/etc/sysctl.conf.append /buildroot/files/configs/etc/sysctl.conf.append

RUN mkdir -p "${OUTPUTDIR}/sp"
ADD rootfs/files/configs/etc/systemd/system/hardening-vm.service ${OUTPUTDIR}/etc/systemd/system/hardening-vm.service
ADD rootfs/files/configs/usr/local/bin/hardening-vm.sh ${OUTPUTDIR}/usr/local/bin/hardening-vm.sh
RUN ln -sf /etc/systemd/system/hardening-vm.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/hardening-vm.service"

# provider-config s3fs mount service (replaces physical provider_config disk)
ADD rootfs/files/configs/etc/systemd/system/provider-config-s3fs.service ${OUTPUTDIR}/etc/systemd/system/provider-config-s3fs.service
ADD rootfs/files/configs/usr/local/bin/mount-provider-config.sh ${OUTPUTDIR}/usr/local/bin/mount-provider-config.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/mount-provider-config.sh
RUN ln -sf /etc/systemd/system/provider-config-s3fs.service \
    "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/provider-config-s3fs.service"

# swarm services
ADD rootfs/files/configs/etc/systemd/system/swarm-db.service ${OUTPUTDIR}/etc/systemd/system/swarm-db.service
RUN ln -sf /etc/systemd/system/swarm-db.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-db.service"
ADD rootfs/files/configs/usr/local/bin/swarm-cloud-api.sh ${OUTPUTDIR}/usr/local/bin/swarm-cloud-api.sh
ADD rootfs/files/configs/etc/systemd/system/swarm-node.service ${OUTPUTDIR}/etc/systemd/system/swarm-node.service
RUN ln -sf /etc/systemd/system/swarm-node.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-node.service"
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/swarm-cloud-api.sh
# run-state directories are prepared in state_disk_mount.sh; bind mounts via fstab
# Temporary debug: Keep default securetty to allow ttyS0 root login
# ADD rootfs/files/configs/etc/securetty "${OUTPUTDIR}/etc/securetty"

# swarm-init: downloads binaries and seeds swarm-db (restarts until MySQL is available)
# generate-swarm-db-config: generates /etc/swarm-db/config.yaml at swarm-db start (ExecStartPre)
# configuration is read from /sp/swarm/config.yaml (attached via provider config disk at boot)
RUN mkdir -p "${OUTPUTDIR}/etc/swarm" "${OUTPUTDIR}/etc/swarm-db" "${OUTPUTDIR}/etc/swarm-node"
ADD rootfs/files/configs/etc/swarm-node/config.yaml ${OUTPUTDIR}/etc/swarm-node/config.yaml
ADD rootfs/files/configs/usr/local/bin/swarm-init.sh ${OUTPUTDIR}/usr/local/bin/swarm-init.sh
ADD rootfs/files/configs/usr/local/bin/generate-swarm-db-config.sh ${OUTPUTDIR}/usr/local/bin/generate-swarm-db-config.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/swarm-init.sh \
          ${OUTPUTDIR}/usr/local/bin/generate-swarm-db-config.sh
ADD rootfs/files/configs/etc/systemd/system/swarm-init.service ${OUTPUTDIR}/etc/systemd/system/swarm-init.service
RUN ln -sf /etc/systemd/system/swarm-init.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-init.service"

# swarm-host-agent: placeholder service file (binary + real service installed by swarm-init at boot)
COPY rootfs/files/configs/etc/systemd/system/swarm-host-agent.service ${OUTPUTDIR}/etc/systemd/system/swarm-host-agent.service

RUN mkdir -p "${OUTPUTDIR}/etc/swarm-service-launchers"
COPY swarm-scripts ${OUTPUTDIR}/etc/swarm-service-launchers/

# swarm one-shot services runner
ADD rootfs/files/configs/etc/systemd/system/swarm-services.service ${OUTPUTDIR}/etc/systemd/system/swarm-services.service
ADD rootfs/files/configs/usr/local/bin/swarm-services.sh ${OUTPUTDIR}/usr/local/bin/swarm-services.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/swarm-services.sh
RUN ln -sf /etc/systemd/system/swarm-services.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-services.service"

# Keep serial getty for debugging
# ADD rootfs/files/configs/usr/lib/systemd/system/serial-getty@.service "${OUTPUTDIR}/usr/lib/systemd/system/serial-getty@.service"
# RUN ln -sf /dev/null "${OUTPUTDIR}/etc/systemd/system/getty@ttyS0.service"

# Debugging: set root password
RUN echo "root:supersecret" | chpasswd -R ${OUTPUTDIR}

# swarm binaries into VM rootfs
RUN mkdir -p "${OUTPUTDIR}/usr/local/lib/swarm-cloud" "${OUTPUTDIR}/usr/local/bin"
ADD rootfs/files/configs/usr/local/bin/swarm-cloud-ui.sh ${OUTPUTDIR}/usr/local/bin/swarm-cloud-ui.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/swarm-cloud-ui.sh
ADD rootfs/files/configs/usr/local/bin/kubectl ${OUTPUTDIR}/usr/local/bin/kubectl
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/kubectl
# swarm-db binary is downloaded at runtime by swarm-init (tags.swarm_db in /sp/swarm/config.yaml)
# provision plugins at /etc/swarm-cloud/services are mounted into the swarm-node container at runtime
RUN mkdir -p "${OUTPUTDIR}/etc/swarm-db" "${OUTPUTDIR}/etc/swarm-services"
COPY repos/swarm-cloud/apps/swarm-node-e2e/fixtures/schema.yaml ${OUTPUTDIR}/etc/swarm-db/schema.yaml


# make /opt/swarm-cloud-api point to built swarm-cloud artifacts
RUN mkdir -p ${OUTPUTDIR}/opt && ln -s /usr/local/lib/swarm-cloud-api ${OUTPUTDIR}/opt/swarm-cloud-api

# swarm-cloud-api runtime wrappers (Node.js entrypoints)
RUN mkdir -p ${OUTPUTDIR}/usr/local/lib/swarm-cloud-api
ADD rootfs/files/configs/usr/local/lib/swarm-cloud-api/swarm-cloud-api ${OUTPUTDIR}/usr/local/lib/swarm-cloud-api/swarm-cloud-api
ADD rootfs/files/configs/usr/local/lib/swarm-cloud-api/schema-sync ${OUTPUTDIR}/usr/local/lib/swarm-cloud-api/schema-sync
RUN chmod +x \
    ${OUTPUTDIR}/usr/local/lib/swarm-cloud-api/swarm-cloud-api \
    ${OUTPUTDIR}/usr/local/lib/swarm-cloud-api/schema-sync

# install Node.js (required by PCCS npm install and swarm-cloud-api)
ADD rootfs/files/scripts/install_nodejs.sh /buildroot/files/scripts/
RUN --security=insecure bash /buildroot/files/scripts/install_nodejs.sh

# install PCCS
ADD rootfs/files/scripts/install_pccs.sh /buildroot/files/scripts/
ADD rootfs/files/configs/pccs-init/ /buildroot/files/configs/pccs-init/
RUN --security=insecure /buildroot/files/scripts/install_pccs.sh
RUN cp /buildroot/files/configs/pccs-init/pccs-init.service "${OUTPUTDIR}/usr/lib/systemd/system/pccs-init.service"
RUN cp /buildroot/files/configs/pccs-init/pccs-init.sh "${OUTPUTDIR}/usr/local/bin/pccs-init.sh"
RUN chmod +x "${OUTPUTDIR}/usr/local/bin/pccs-init.sh"
RUN ln -s /usr/lib/systemd/system/pccs-init.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pccs-init.service"

# Custom swarm services
RUN mkdir -p ${OUTPUTDIR}/etc/swarm-services/

# tools needed at runtime (prevent daemons from starting in chroot) and runtime setup
ADD rootfs/files/scripts/setup_runtime_tools.sh /buildroot/files/scripts/
RUN chmod +x /buildroot/files/scripts/setup_runtime_tools.sh
RUN --security=insecure /buildroot/files/scripts/setup_runtime_tools.sh


# Python dependencies required by provision plugins (redis-py for rke2/redis plugins, podman-compose for container plugins)
ADD rootfs/files/scripts/install_python_deps.sh /buildroot/files/scripts/
RUN --security=insecure bash /buildroot/files/scripts/install_python_deps.sh

# Extra system packages required by provision plugins at runtime
# mysql-client: bootstrap-services.sh and provision plugins use mysql CLI to talk to SwarmDB
# unzip: download-services.sh extracts service archives
# netcat-openbsd: provision plugins use nc for port readiness checks (e.g. cockroachdb plugin)
# dnsutils: DNS tools (nsupdate) used by rke2 plugin for Knot DNS updates
ADD rootfs/files/scripts/install_extra_packages.sh /buildroot/files/scripts/
RUN --security=insecure bash /buildroot/files/scripts/install_extra_packages.sh

# Build info
ARG SP_VM_IMAGE_VERSION
RUN bash -c '[[ -n "$SP_VM_IMAGE_VERSION" ]] && echo "$SP_VM_IMAGE_VERSION" > "${OUTPUTDIR}/etc/sp-release"'

# after all!
# cleanup apt lists and policy-rc.d
RUN rm -f ${OUTPUTDIR}/usr/sbin/policy-rc.d
ADD rootfs/files/scripts/cleanup_rootfs.sh /buildroot/files/scripts/
RUN --security=insecure /buildroot/files/scripts/cleanup_rootfs.sh
### End rootfs ###

### Start image ###
FROM ubuntu:24.04 AS image_builder
ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt -y install qemu-utils grub-pc parted udev fdisk e2fsprogs dosfstools kpartx cryptsetup-bin
RUN apt -y install grub-efi  # this needs to be installed separately!

ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

# is required by passing build arg, value example: SP_VM_IMAGE_VERSION=build-1
ARG SP_VM_IMAGE_VERSION
ARG KERNEL_VERSION=6.12.13

WORKDIR /output
ADD general/files/scripts/log.sh /buildroot/files/scripts/

ADD image/files/scripts/create_image.sh /buildroot/files/scripts/
ADD image/files/configs/grub.cfg.tmpl /buildroot/files/configs/
RUN --mount=type=bind,target=/output/rootfs,readonly,from=rootfs_builder,source=/output/rootfs --security=insecure \
    /buildroot/files/scripts/create_image.sh
### End image ###

### Start ovmf_builder_base ###
FROM ubuntu:24.04 AS ovmf_builder_base
RUN apt update && apt install -y wget gcc make build-essential git uuid-dev python-is-python3 nasm iasl dpkg-dev lsb-release quilt

WORKDIR /buildroot

ADD bios/files/configs/gitconfig /root/.gitconfig
### End ovmf_builder_base ###

### Start ovmf_builder_sev ###
FROM ovmf_builder_base AS ovmf_builder_sev
RUN git clone --single-branch --depth 1 --branch edk2-stable202508 https://github.com/tianocore/edk2.git ovmf
WORKDIR /buildroot/ovmf
ADD bios/files/configs/AmdSev-support-vm-over-1TB.patch /buildroot/ovmf
RUN git apply AmdSev-support-vm-over-1TB.patch
RUN git submodule update --init --recursive

RUN make -C BaseTools
ADD bios/files/configs/target_amd_sev.txt /buildroot/ovmf/Conf/target.txt
RUN touch OvmfPkg/AmdSev/Grub/grub.efi
RUN bash -c 'source /buildroot/ovmf/edksetup.sh && build clean'
RUN bash -c 'source /buildroot/ovmf/edksetup.sh && build'
RUN test -f Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd
### End ovmf_builder_sev ###

### Start ovmf_builder_tdx ###
FROM ovmf_builder_base AS ovmf_builder_tdx
WORKDIR /buildroot/src/
RUN wget -O /buildroot/src/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.debian.tar.xz https://code.launchpad.net/~kobuk-team/+archive/ubuntu/tdx/+sourcefiles/edk2/2024.05-2ubuntu0.1+tdx1.0~ppa1/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.debian.tar.xz
RUN wget -O /buildroot/src/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.dsc https://code.launchpad.net/~kobuk-team/+archive/ubuntu/tdx/+sourcefiles/edk2/2024.05-2ubuntu0.1+tdx1.0~ppa1/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.dsc
RUN wget -O /buildroot/src/edk2_2024.05.orig.tar.xz https://code.launchpad.net/~kobuk-team/+archive/ubuntu/tdx/+sourcefiles/edk2/2024.05-2ubuntu0.1+tdx1.0~ppa1/edk2_2024.05.orig.tar.xz
RUN dpkg-source -x /buildroot/src/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.dsc /buildroot/edk2_build
WORKDIR /buildroot/edk2_build
# RUN apt update && apt -y build-dep ./
RUN make -C BaseTools
ADD bios/files/configs/0001-SuperProtocol_Rtmr0.patch /buildroot/edk2_build/debian/patches/SuperProtocol/
RUN quilt import -p0 debian/patches/SuperProtocol/0001-SuperProtocol_Rtmr0.patch
RUN quilt push
ADD bios/files/scripts/build_ovmf_tdx.sh /buildroot/files/scripts/
ADD general/files/scripts/log.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/build_ovmf_tdx.sh
RUN test -f Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd

### End ovmf_builder_tdx ###

### Start vm_json_builder ###
FROM ubuntu:24.04 AS vm_json_builder
ARG SP_VM_IMAGE_VERSION
ARG S3_BUCKET
COPY --from=image_builder /output /output
COPY --from=ovmf_builder_sev /buildroot/ovmf/Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd /output/OVMF_AMD.fd
COPY --from=ovmf_builder_tdx /buildroot/edk2_build/Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd /output/OVMF.fd
COPY --from=kernel_builder /output/boot/vmlinuz-6.12.13-nvidia-gpu-confidential /output/vmlinuz
ADD bundle/files/scripts/generate_vm_json.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/generate_vm_json.sh
### End vm_json_builder ###

### Start vm_json_cloud_builder ###
FROM ubuntu:24.04 AS vm_json_cloud_builder
ARG SP_VM_IMAGE_VERSION
ARG S3_BUCKET
COPY --from=image_builder /output /output
COPY --from=ovmf_builder_sev /buildroot/ovmf/Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd /output/OVMF_AMD.fd
COPY --from=ovmf_builder_tdx /buildroot/edk2_build/Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd /output/OVMF.fd
COPY --from=kernel_builder /output/boot/vmlinuz-6.12.13-nvidia-gpu-confidential /output/vmlinuz
ADD bundle/files/scripts/generate_vm_json.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/generate_vm_json.sh
### End vm_json_cloud_builder ###

### Start sp_vm_cloud ###
FROM scratch AS sp_vm_cloud
COPY --from=vm_json_cloud_builder /output /
### End sp_vm_cloud ###

### Start sp_vm ###
FROM scratch AS sp_vm
COPY --from=vm_json_builder /output /
### End sp_vm ###
