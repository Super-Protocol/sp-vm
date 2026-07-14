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
ARG KERNEL_SHA256=191dc5aae14a4223f0d5ce4e88cbbd29f0377703b9f0b70d4903734de641fb6a

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
FROM ubuntu:noble-20250714@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061 AS rootfs_base

ARG UBUNTU_SNAPSHOT_ID=20260714T000000Z
ARG SOURCE_DATE_EPOCH=1783987200
RUN rm -f /etc/apt/sources.list.d/ubuntu.sources \
    && printf 'deb http://archive.ubuntu.com/ubuntu/ noble main\n' > /etc/apt/sources.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates \
    && printf '%s\n' \
        'deb http://archive.ubuntu.com/ubuntu/ noble main universe' \
        'deb http://archive.ubuntu.com/ubuntu/ noble-updates main universe' \
        'deb http://security.ubuntu.com/ubuntu/ noble-security main universe' \
        > /etc/apt/sources.list \
    && printf 'APT::Snapshot "%s";\nAPT::Get::Always-Include-Phased-Updates "true";\nAcquire::Languages "none";\n' \
        "$UBUNTU_SNAPSHOT_ID" > /etc/apt/apt.conf.d/50snapshot \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        wget gcc make build-essential debootstrap petname gettext \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG PROVIDER_CONFIG_DST=/sp
ARG VERSION_CODENAME=noble
ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs
ARG SP_VM_BUILD_TYPE=debug

WORKDIR /buildroot

ADD general/files/scripts/log.sh /buildroot/files/scripts/

ADD rootfs/files/scripts/create_base_system.sh /buildroot/files/scripts/
ADD rootfs/files/configs/etc/resolv.conf /buildroot/files/configs/etc/resolv.conf
RUN /buildroot/files/scripts/create_base_system.sh

FROM rootfs_base AS rootfs_base_artifact
ADD rootfs/files/scripts/export_base_system.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/export_base_system.sh

FROM scratch AS rootfs_base_export
COPY --from=rootfs_base_artifact /output/rootfs-base-artifacts/ /

FROM rootfs_base AS rootfs_builder

COPY --from=kernel_builder /output/deb ${OUTPUTDIR}/kernel_deb
ADD rootfs/files/scripts/install_kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/install_kernel.sh

ADD general/files/scripts/chroot.sh /buildroot/files/scripts/
ADD rootfs/files/scripts/install_nvidia.sh /buildroot/files/scripts/
RUN --security=insecure /buildroot/files/scripts/install_nvidia.sh
ADD rootfs/files/scripts/install_gve.sh /buildroot/files/scripts/install_gve.sh
RUN --security=insecure /buildroot/files/scripts/install_gve.sh

# Install s3fs-fuse for provider_config S3 bucket mounting
ADD rootfs/files/scripts/install_s3fs.sh /buildroot/files/scripts/
RUN --security=insecure /buildroot/files/scripts/install_s3fs.sh
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

# ensure system boots into multi-user.target instead of graphical.target
RUN ln -sf "/lib/systemd/system/multi-user.target" "${OUTPUTDIR}/etc/systemd/system/default.target"

RUN cp "${OUTPUTDIR}/usr/share/systemd/tmp.mount" "${OUTPUTDIR}/etc/systemd/system/tmp.mount";

ADD rootfs/files/configs/01-netplan.yaml ${OUTPUTDIR}/etc/netplan/
ADD rootfs/files/configs/fstab ${OUTPUTDIR}/etc/
ADD rootfs/files/configs/tdx-attest.conf ${OUTPUTDIR}/etc/

ADD rootfs/files/configs/chrony/chrony.conf ${OUTPUTDIR}/etc/chrony/
ADD rootfs/files/configs/chrony/chrony.service ${OUTPUTDIR}/etc/systemd/system/chrony.service
RUN ln -sf /etc/systemd/system/chrony.service \
    "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/chrony.service"

RUN if [ "$SP_VM_BUILD_TYPE" = "release" ]; then \
        sed -i '1 s|^.*$|-:root:ALL|' "${OUTPUTDIR}/etc/security/access.conf"; \
        sed -i '1 s|^.*$|account required pam_access.so|' "${OUTPUTDIR}/etc/pam.d/login"; \
    fi
ADD rootfs/files/configs/nvidia-persistenced.service ${OUTPUTDIR}/usr/lib/systemd/system/

RUN echo "sp-$(petname)" > "${OUTPUTDIR}/etc/hostname"
RUN mkdir -p "${OUTPUTDIR}/etc/rancher/rke2"
ADD rootfs/files/configs/etc/cni/podman/net.d/87-podman-bridge.conflist \
    ${OUTPUTDIR}/etc/cni/podman/net.d/87-podman-bridge.conflist
ADD rootfs/files/configs/etc/containers/containers.conf.d/99-podman-cni-dir.conf \
    ${OUTPUTDIR}/etc/containers/containers.conf.d/99-podman-cni-dir.conf
ADD rootfs/files/configs/usr/local/bin/configure-podman-cni.sh ${OUTPUTDIR}/usr/local/bin/configure-podman-cni.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/configure-podman-cni.sh
ADD rootfs/files/configs/etc/systemd/system/configure-podman-cni.service \
    ${OUTPUTDIR}/etc/systemd/system/configure-podman-cni.service
RUN ln -sf /etc/systemd/system/configure-podman-cni.service \
    "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/configure-podman-cni.service"
RUN mkdir -p "${OUTPUTDIR}/etc/apt/apt.conf.d"
ADD rootfs/files/configs/etc/apt/apt.conf.d/99-sp-configure-podman-cni \
    ${OUTPUTDIR}/etc/apt/apt.conf.d/99-sp-configure-podman-cni

# copy iscsi configs, cause this partition will be remounted with empty dir
RUN mkdir -p "${OUTPUTDIR}/etc/iscsi"
RUN cp -r "${OUTPUTDIR}/etc/iscsi/" "${OUTPUTDIR}/etc/super/etc/";
ADD rootfs/files/scripts/setup_sshd_config.sh /buildroot/files/scripts/setup_sshd_config.sh
RUN /buildroot/files/scripts/setup_sshd_config.sh

RUN mkdir -p "${OUTPUTDIR}/usr/local/bin";

# copy pki service files
RUN mkdir -p "${OUTPUTDIR}/usr/local/bin/pki-authority"
ADD rootfs/files/configs/pki-service/scripts/*.py "${OUTPUTDIR}/usr/local/bin/pki-authority/"
ADD rootfs/files/configs/pki-service/scripts/*.sh "${OUTPUTDIR}/usr/local/bin/pki-authority/"
ADD rootfs/files/configs/pki-service/systemd/pki-authority-sync.service "${OUTPUTDIR}/etc/systemd/system"
ADD rootfs/files/configs/pki-service/systemd/pki-cert-init.service "${OUTPUTDIR}/etc/systemd/system"
ADD rootfs/files/configs/pki-service/systemd/pki-vm-mode.service "${OUTPUTDIR}/etc/systemd/system"
ADD rootfs/files/configs/pki-service/systemd/pki-vm-measurements.service "${OUTPUTDIR}/etc/systemd/system"
ADD rootfs/files/configs/pki-service/systemd/pki-vm-measurements-healthcheck.service "${OUTPUTDIR}/etc/systemd/system"
ADD rootfs/files/configs/pki-service/systemd/pki-vm-measurements-healthcheck.timer "${OUTPUTDIR}/etc/systemd/system"
RUN mkdir -p "${OUTPUTDIR}/etc/super/pki-authority-sync"
ADD rootfs/files/configs/pki-service/conf/secrets-config.yaml "${OUTPUTDIR}/etc/super/pki-authority-sync/secrets-config.yaml"
RUN mkdir -p "${OUTPUTDIR}/etc/super/pki-cert-generator"
ADD rootfs/files/configs/pki-service/conf/cert-gen-config-template.yaml "${OUTPUTDIR}/etc/super/pki-cert-generator/cert-gen-config-template.yaml"
RUN chmod +x "${OUTPUTDIR}"/usr/local/bin/pki-authority/*.py
RUN mkdir -p "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants" "${OUTPUTDIR}/etc/systemd/system/timers.target.wants"
RUN ln -s /etc/systemd/system/pki-authority-sync.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pki-authority-sync.service"
RUN ln -s /etc/systemd/system/pki-cert-init.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pki-cert-init.service"
RUN ln -s /etc/systemd/system/pki-vm-measurements.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pki-vm-measurements.service"
RUN ln -s /etc/systemd/system/pki-vm-measurements-healthcheck.timer "${OUTPUTDIR}/etc/systemd/system/timers.target.wants/pki-vm-measurements-healthcheck.timer"

ADD rootfs/files/configs/etc/multipath.conf.append /buildroot/files/configs/etc/multipath.conf.append
ADD rootfs/files/configs/etc/sysctl.conf.append /buildroot/files/configs/etc/sysctl.conf.append

RUN mkdir -p "${OUTPUTDIR}/sp"
ADD rootfs/files/configs/etc/systemd/system/hardening-vm.service ${OUTPUTDIR}/etc/systemd/system/hardening-vm.service
ADD rootfs/files/configs/usr/local/bin/hardening-vm.sh ${OUTPUTDIR}/usr/local/bin/hardening-vm.sh
RUN ln -sf /etc/systemd/system/hardening-vm.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/hardening-vm.service"

# provider-config s3fs mount service (replaces physical provider_config disk)
ADD rootfs/files/configs/etc/systemd/system/provider-config-s3fs.service ${OUTPUTDIR}/etc/systemd/system/provider-config-s3fs.service
ADD rootfs/files/configs/usr/local/bin/mount-provider-config.sh ${OUTPUTDIR}/usr/local/bin/mount-provider-config.sh
ADD rootfs/files/configs/etc/systemd/system/sp-tap-network.service ${OUTPUTDIR}/etc/systemd/system/sp-tap-network.service
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/mount-provider-config.sh
RUN ln -sf /etc/systemd/system/provider-config-s3fs.service \
    "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/provider-config-s3fs.service"
RUN ln -sf /etc/systemd/system/sp-tap-network.service \
    "${OUTPUTDIR}/etc/systemd/system/sysinit.target.wants/sp-tap-network.service"
ADD rootfs/files/configs/usr/local/bin/sp-tap-network.sh ${OUTPUTDIR}/usr/local/bin/sp-tap-network.sh
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/sp-tap-network.sh

# swarm services
ADD rootfs/files/configs/etc/systemd/system/swarm-db.service ${OUTPUTDIR}/etc/systemd/system/swarm-db.service
RUN ln -sf /etc/systemd/system/swarm-db.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-db.service"
#ADD rootfs/files/scripts/prepare_swarm_db_config.py ${OUTPUTDIR}/usr/local/bin/prepare_swarm_db_config.py
#RUN chmod +x ${OUTPUTDIR}/usr/local/bin/prepare_swarm_db_config.py
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
RUN case "$SP_VM_BUILD_TYPE" in \
        debug) printf 'untrusted\n' > "${OUTPUTDIR}/etc/swarm/swarm-network-type" ;; \
        release) printf 'trusted\n' > "${OUTPUTDIR}/etc/swarm/swarm-network-type" ;; \
        *) echo "Unsupported SP_VM_BUILD_TYPE: $SP_VM_BUILD_TYPE" >&2; exit 1 ;; \
    esac
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

# Enable interactive serial console login only for debug builds.
RUN if [ "$SP_VM_BUILD_TYPE" = "debug" ]; then \
        mkdir -p "${OUTPUTDIR}/etc/systemd/system/getty.target.wants"; \
        ln -sf "/lib/systemd/system/serial-getty@.service" "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"; \
        if [ -f "${OUTPUTDIR}/etc/securetty" ] && ! grep -qx ttyS0 "${OUTPUTDIR}/etc/securetty"; then \
            echo ttyS0 >> "${OUTPUTDIR}/etc/securetty"; \
        fi; \
        echo "root:supersecret" | chpasswd -R "${OUTPUTDIR}"; \
    else \
        ln -sf /dev/null "${OUTPUTDIR}/etc/systemd/system/serial-getty@ttyS0.service"; \
        rm -f "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"; \
    fi

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
ADD rootfs/files/configs/pki-service/sgx_default_qcnl.conf ${OUTPUTDIR}/etc/sgx_default_qcnl.conf
ADD rootfs/files/configs/pccs-init/pccs-init.service "${OUTPUTDIR}/usr/lib/systemd/system/pccs-init.service"
ADD rootfs/files/configs/pccs-init/pccs-init.sh "${OUTPUTDIR}/usr/local/bin/pccs-init.sh"
RUN chmod +x "${OUTPUTDIR}/usr/local/bin/pccs-init.sh"
RUN ln -s /usr/lib/systemd/system/pccs-init.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pccs-init.service"

# Custom swarm services
RUN mkdir -p ${OUTPUTDIR}/etc/swarm-services/

# tools needed at runtime (prevent daemons from starting in chroot) and runtime setup
ADD rootfs/files/scripts/setup_runtime_tools.sh /buildroot/files/scripts/
RUN chmod +x /buildroot/files/scripts/setup_runtime_tools.sh
RUN --security=insecure /buildroot/files/scripts/setup_runtime_tools.sh

# install PKI npm components globally (requires python3-venv from setup_runtime_tools)
ARG PKI_SYNC_CLIENT_VERSION=5.0.6
ARG PKI_CERT_GENERATOR_VERSION=5.0.2
ARG PKI_VM_MEASUREMENTS_VERSION=1.0.3
ADD rootfs/files/scripts/install_pki_components.sh /buildroot/files/scripts/
RUN chmod +x /buildroot/files/scripts/install_pki_components.sh
RUN --security=insecure /buildroot/files/scripts/install_pki_components.sh \
    "${PKI_SYNC_CLIENT_VERSION}" "${PKI_CERT_GENERATOR_VERSION}" "${PKI_VM_MEASUREMENTS_VERSION}"

# Extra system packages required by provision plugins at runtime
# mysql-client: bootstrap-services.sh and provision plugins use mysql CLI to talk to SwarmDB
# unzip: download-services.sh extracts service archives
# netcat-openbsd: provision plugins use nc for port readiness checks (e.g. cockroachdb plugin)
# dnsutils: DNS tools (nsupdate) used by rke2 plugin for Knot DNS updates
ADD rootfs/files/configs/etc/dpkg/dpkg.cfg.d/force-confold ${OUTPUTDIR}/etc/dpkg/dpkg.cfg.d/force-confold
ADD rootfs/files/scripts/install_extra_packages.sh /buildroot/files/scripts/
RUN --security=insecure bash /buildroot/files/scripts/install_extra_packages.sh

# Python dependencies required by provision plugins (redis-py for rke2/redis plugins, podman-compose for container plugins)
ADD rootfs/files/scripts/install_python_deps.sh /buildroot/files/scripts/
RUN --security=insecure bash /buildroot/files/scripts/install_python_deps.sh

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
ARG OVMF_TDX_SHA256=b07df0e4f75c46408bc7a73c943003cfda6b546c4a7fa8fed2410bd944be35dd
RUN wget -O /buildroot/src/ovmf_2024.05-2ubuntu0.1+tdx1.0_all.deb https://ppa.launchpadcontent.net/kobuk-team/tdx-release/ubuntu/pool/main/e/edk2/ovmf_2024.05-2ubuntu0.1+tdx1.0_all.deb
RUN echo "${OVMF_TDX_SHA256}  /buildroot/src/ovmf_2024.05-2ubuntu0.1+tdx1.0_all.deb" | sha256sum -c -
RUN dpkg-deb -x /buildroot/src/ovmf_2024.05-2ubuntu0.1+tdx1.0_all.deb /buildroot/ovmf_tdx
RUN test -f /buildroot/ovmf_tdx/usr/share/ovmf/OVMF.fd

### End ovmf_builder_tdx ###

### Start ovmf_centos_tdx ###
FROM ubuntu:24.04 AS ovmf_centos_tdx
RUN apt-get update && apt-get install -y wget rpm2cpio cpio
RUN wget -O /tmp/edk2-ovmf.rpm https://mirror.stream.centos.org/10-stream/AppStream/x86_64/os/Packages/edk2-ovmf-20260221-3.el10.noarch.rpm
RUN cd /tmp && rpm2cpio edk2-ovmf.rpm | cpio -idm './usr/share/edk2/ovmf/OVMF.inteltdx.fd'
RUN test -f /tmp/usr/share/edk2/ovmf/OVMF.inteltdx.fd
### End ovmf_centos_tdx ###

### Start vm_json_builder ###
FROM ubuntu:24.04 AS vm_json_builder
ARG SP_VM_IMAGE_VERSION
ARG S3_BUCKET
COPY --from=image_builder /output /output
COPY --from=ovmf_builder_sev /buildroot/ovmf/Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd /output/OVMF_AMD.fd
COPY --from=ovmf_builder_tdx /buildroot/ovmf_tdx/usr/share/ovmf/OVMF.fd /output/OVMF.fd
COPY --from=ovmf_centos_tdx /tmp/usr/share/edk2/ovmf/OVMF.inteltdx.fd /output/OVMF_TDX.fd
COPY --from=kernel_builder /output/boot/vmlinuz-6.12.13-nvidia-gpu-confidential /output/vmlinuz
ADD bundle/files/scripts/generate_vm_json.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/generate_vm_json.sh
### End vm_json_builder ###


### Start sp_vm ###
FROM scratch AS sp_vm
COPY --from=vm_json_builder /output /
### End sp_vm ###
