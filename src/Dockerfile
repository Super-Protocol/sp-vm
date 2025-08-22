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
RUN make -j blkid LDFLAGS="--static"
RUN strip blkid
RUN mkdir -p /initramfs-root/sbin
RUN cp /tmp/util-linux-${util_linux_version}/blkid /initramfs-root/sbin/blkid
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

### Start initramfs ###
FROM gen_init_cpio_builder AS initramfs_builder
COPY --from=busybox_builder /initramfs-root/sbin/busybox /initramfs-root/sbin/
COPY --from=util_linux_builder /initramfs-root/sbin/blkid /initramfs-root/sbin/
COPY --from=cryptsetup_builder /initramfs-root/sbin/veritysetup.static /initramfs-root/sbin/
ADD initramfs/files/initramfs.list /initramfs-root/initramfs.list
ADD initramfs/files/init.sh /initramfs-root/sbin/init.sh
RUN gen_init_cpio /initramfs-root/initramfs.list | gzip -9 -n > /initramfs-root/initramfs.cpio.gz
### End  ###

### Start certs ###
FROM ubuntu:24.04 AS certs_builder
RUN apt update && apt install -y openssl

WORKDIR /buildroot
ARG SUPER_REGISTRY_HOST=registry.superprotocol.local
RUN openssl genrsa \
    -out "/buildroot/${SUPER_REGISTRY_HOST}.ca.key" 2048;
RUN openssl req -x509 -new -nodes \
    -key "/buildroot/${SUPER_REGISTRY_HOST}.ca.key" \
    -sha256 -days 3650 \
    -out "/buildroot/${SUPER_REGISTRY_HOST}.ca.crt" \
    -subj "/ST=Milk Galaxy/L=Planet Earth/O=SuperProtocol/OU=MyUnit/CN=SuperProtocol.com"
RUN openssl genrsa \
    -out "/buildroot/${SUPER_REGISTRY_HOST}.key" 2048;
RUN printf "[req]\ndefault_bits = 2048\nprompt = no\ndistinguished_name = req_distinguished_name\nreq_extensions = req_ext\n[req_distinguished_name]\nC = US\nST = Milk Galaxy\nL = Planet Earth\nO = SuperProtocol\nOU = MyUnit\nCN = ${SUPER_REGISTRY_HOST}\n[req_ext]\nsubjectAltName = @alt_names\n[alt_names]\nDNS.1 = ${SUPER_REGISTRY_HOST}\n[v3_ext]\nsubjectAltName = @alt_names\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment\n" > "/buildroot/san.cnf"
RUN openssl req -new \
    -key "/buildroot/${SUPER_REGISTRY_HOST}.key" \
    -out "/buildroot/${SUPER_REGISTRY_HOST}.csr" \
    -config /buildroot/san.cnf
RUN openssl x509 -req \
    -in "/buildroot/${SUPER_REGISTRY_HOST}.csr" \
    -CA "/buildroot/${SUPER_REGISTRY_HOST}.ca.crt" \
    -CAkey "/buildroot/${SUPER_REGISTRY_HOST}.ca.key" \
    -CAcreateserial \
    -out "/buildroot/${SUPER_REGISTRY_HOST}.crt" \
    -days 3650 -sha256 \
    -extfile "/buildroot/san.cnf" \
    -extensions v3_ext
### End certs ###

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

### Start hauler ###
FROM ubuntu:24.04 AS hauler_builder
RUN apt update && apt -y install curl
ARG HAULER_VERSION="1.1.0"
RUN mkdir -p "/opt/hauler/.hauler"
RUN ln -s "/opt/hauler/.hauler" "/root/.hauler"
RUN curl -sfL https://get.hauler.dev | bash
WORKDIR /opt/hauler
ADD hauler/files/configs/rke2-airgap.yaml /opt/hauler/rke2-airgap.yaml
RUN hauler store sync --store rke2-store --platform linux/amd64 --files /opt/hauler/rke2-airgap.yaml
RUN rm /opt/hauler/rke2-airgap.yaml
RUN hauler store add --store rke2-store image ghcr.io/super-protocol/tee-pki-curl:v1.7.4 --platform linux/amd64
# TODO: add argo-cd, argo-workflows, cert-manager, gpu-operator, longhorn charts
RUN hauler store save --store rke2-store --filename rke2-airgap.tar.zst
### End hauler ###

### Start rootfs ###
FROM ubuntu:noble-20250714 AS rootfs_builder
RUN apt update && apt install -y wget gcc make build-essential debootstrap

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

RUN mkdir -p "${OUTPUTDIR}/etc/systemd/system/getty.target.wants"
RUN ln -sf "/lib/systemd/system/getty@.service" "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/getty@ttyS0.service"

RUN cp "${OUTPUTDIR}/usr/share/systemd/tmp.mount" "${OUTPUTDIR}/etc/systemd/system/tmp.mount";

ADD rootfs/files/configs/01-netplan.yaml ${OUTPUTDIR}/etc/netplan/
ADD rootfs/files/configs/fstab ${OUTPUTDIR}/etc/
ADD rootfs/files/configs/tdx-attest.conf ${OUTPUTDIR}/etc/

ADD rootfs/files/configs/chrony/chrony.conf ${OUTPUTDIR}/etc/chrony/
ADD rootfs/files/configs/chrony/chrony.service ${OUTPUTDIR}/lib/systemd/system/

ADD rootfs/files/configs/state_disk_mount/state_disk_mount.service ${OUTPUTDIR}/etc/systemd/system/
ADD rootfs/files/configs/state_disk_mount/state_disk_mount.sh ${OUTPUTDIR}/usr/local/bin/
RUN ln -s /etc/systemd/system/state_disk_mount.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/state_disk_mount.service"
RUN sed -i '1 s|^.*$|-:root:ALL|' "${OUTPUTDIR}/etc/security/access.conf"
RUN sed -i '1 s|^.*$|account required pam_access.so|' "${OUTPUTDIR}/etc/pam.d/login"
ADD rootfs/files/configs/nvidia-persistenced.service ${OUTPUTDIR}/usr/lib/systemd/system/

RUN mkdir -p "${OUTPUTDIR}/etc/super/certs"
COPY --from=certs_builder /buildroot/registry.superprotocol.local.ca.crt ${OUTPUTDIR}/usr/local/share/ca-certificates/registry.superprotocol.local.ca.crt
COPY --from=certs_builder /buildroot/registry.superprotocol.local.ca.crt ${OUTPUTDIR}/etc/super/certs/registry.superprotocol.local.ca.crt
COPY --from=certs_builder /buildroot/registry.superprotocol.local.key ${OUTPUTDIR}/etc/super/certs/registry.superprotocol.local.key
COPY --from=certs_builder /buildroot/registry.superprotocol.local.crt ${OUTPUTDIR}/etc/super/certs/registry.superprotocol.local.crt
ADD rootfs/files/configs/cert/superprotocol-certs.sh ${OUTPUTDIR}/usr/local/bin/
ADD rootfs/files/configs/cert/superprotocol-certs.service ${OUTPUTDIR}/etc/systemd/system
RUN ln -s /etc/systemd/system/superprotocol-certs.service ${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/superprotocol-certs.service
ADD rootfs/files/scripts/refresh_ca_certs.sh /buildroot/files/scripts/refresh_ca_certs.sh
RUN --security=insecure /buildroot/files/scripts/refresh_ca_certs.sh

# check for presence of trusted self-signed CA from Super Protocol
RUN awk -v cmd='openssl x509 -noout -subject' '/BEGIN/{close(cmd)};{print | cmd}' < ${OUTPUTDIR}/etc/ssl/certs/ca-certificates.crt | grep -i 'super'

# todo: move upper
RUN apt install -y petname gettext
ARG LOCAL_REGISTRY_HOST=hauler.local
ARG SUPER_REGISTRY_HOST=registry.superprotocol.local
RUN echo "127.0.0.1 $SUPER_REGISTRY_HOST $LOCAL_REGISTRY_HOST" >> "${OUTPUTDIR}/etc/hosts"
RUN echo "sp-$(petname)" > "${OUTPUTDIR}/etc/hostname"
RUN mkdir -p "${OUTPUTDIR}/etc/rancher/node"
RUN LC_ALL=C tr -dc '[:alpha:][:digit:]' < /dev/urandom | head -c 32 > "${OUTPUTDIR}/etc/rancher/node/password"
ADD rootfs/files/configs/etc/cni/net.d/05-cilium.conflist ${OUTPUTDIR}/etc/cni/net.d/05-cilium.conflist
ADD rootfs/files/configs/etc/sysctl.d/99-zzz-override_cilium.conf ${OUTPUTDIR}/etc/sysctl.d/99-zzz-override_cilium.conf
ADD rootfs/files/configs/var/lib/rancher/rke2/rke2-pss.yaml ${OUTPUTDIR}/var/lib/rancher/rke2/rke2-pss.yaml
ADD rootfs/files/configs/etc/resolv.conf ${OUTPUTDIR}/etc/resolv.conf

# copy iscsi configs, cause this partition will be remounted with empty dir
RUN cp -r "${OUTPUTDIR}/etc/iscsi/" "${OUTPUTDIR}/etc/super/etc/";
ADD rootfs/files/scripts/setup_sshd_config.sh /buildroot/files/scripts/setup_sshd_config.sh
RUN /buildroot/files/scripts/setup_sshd_config.sh

RUN mkdir -p "$OUTPUTDIR/etc/super/opt/hauler";
RUN mkdir -p "${OUTPUTDIR}/usr/local/bin";
RUN ln -sf "/opt/hauler/.hauler" "${OUTPUTDIR}/root/.hauler";
COPY --from=hauler_builder /opt/hauler/rke2-airgap.tar.zst ${OUTPUTDIR}/etc/super/opt/hauler/
COPY --from=hauler_builder /usr/local/bin/hauler ${OUTPUTDIR}/usr/local/bin/

# TODO: move hauler and rke2? to anuther independent layers..

ADD rootfs/files/configs/etc/rancher/rke2/config.yaml.tmpl /buildroot/files/configs/etc/rancher/rke2/config.yaml.tmpl
ADD rootfs/files/configs/etc/rancher/rke2/registries.yaml.tmpl /buildroot/files/configs/etc/rancher/rke2/registries.yaml.tmpl
ADD rootfs/files/scripts/template_rke2_configs_preinstall.sh /buildroot/files/scripts/template_rke2_configs_preinstall.sh
RUN /buildroot/files/scripts/template_rke2_configs_preinstall.sh
ADD rootfs/files/scripts/download_rke2.sh /buildroot/files/scripts/download_rke2.sh
RUN /buildroot/files/scripts/download_rke2.sh
ADD rootfs/files/scripts/install_rke2.sh /buildroot/files/scripts/install_rke2.sh
RUN --security=insecure /buildroot/files/scripts/install_rke2.sh
ADD rootfs/files/configs/etc/super/var/lib/rancher/rke2/rke2-pss.yaml ${OUTPUTDIR}/etc/super/var/lib/rancher/rke2/rke2-pss.yaml

ADD rootfs/files/scripts/template_configs_post_rke2install.sh /buildroot/files/scripts/template_configs_post_rke2install.sh
ADD rootfs/files/configs/etc/super/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl.tmpl /buildroot/files/configs/etc/super/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl.tmpl
ADD rootfs/files/configs/usr/local/lib/systemd/system/rke2-server.env.append /buildroot/files/configs/usr/local/lib/systemd/system/rke2-server.env.append
ADD rootfs/files/configs/etc/multipath.conf.append /buildroot/files/configs/etc/multipath.conf.append
ADD rootfs/files/configs/etc/sysctl.conf.append /buildroot/files/configs/etc/sysctl.conf.append
RUN /buildroot/files/scripts/template_configs_post_rke2install.sh

RUN mkdir -p "${OUTPUTDIR}/sp"
ADD rootfs/files/configs/etc/super/var/lib/rancher/rke2/server/manifests/k8s.yaml ${OUTPUTDIR}/etc/super/var/lib/rancher/rke2/server/manifests/k8s.yaml
ADD rootfs/files/configs/etc/systemd/system/check-config-files.service ${OUTPUTDIR}/etc/systemd/system/check-config-files.service
ADD rootfs/files/configs/etc/systemd/system/check-config-files.timer ${OUTPUTDIR}/etc/systemd/system/check-config-files.timer
ADD rootfs/files/configs/usr/local/bin/check-config-files.sh ${OUTPUTDIR}/usr/local/bin/check-config-files.sh
RUN ln -sf /etc/systemd/system/check-config-files.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/check-config-files.service"
RUN ln -sf /etc/systemd/system/check-config-files.timer "${OUTPUTDIR}/etc/systemd/system/timers.target.wants/check-config-files.timer"
ADD rootfs/files/configs/etc/systemd/system/local-registry.service ${OUTPUTDIR}/etc/systemd/system/local-registry.service
ADD rootfs/files/configs/usr/local/bin/local-registry.sh ${OUTPUTDIR}/usr/local/bin/local-registry.sh
RUN ln -sf /etc/systemd/system/local-registry.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/local-registry.service"
ADD rootfs/files/configs/etc/systemd/system/hardening-vm.service ${OUTPUTDIR}/etc/systemd/system/hardening-vm.service
ADD rootfs/files/configs/usr/local/bin/hardening-vm.sh ${OUTPUTDIR}/usr/local/bin/hardening-vm.sh
RUN ln -sf /etc/systemd/system/hardening-vm.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/hardening-vm.service"
ADD rootfs/files/configs/etc/securetty "${OUTPUTDIR}/etc/securetty"

# after all!
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
RUN git clone --single-branch --depth 1 --branch edk2-stable202411 https://github.com/tianocore/edk2.git ovmf
WORKDIR /buildroot/ovmf
RUN git fetch origin 8b87eb9dfba054331ed16204f36c4885aefc3c94
RUN git checkout -b fix-build edk2-stable202411
RUN git cherry-pick 8b87eb9dfba054331ed16204f36c4885aefc3c94
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
ADD https://code.launchpad.net/~kobuk-team/+archive/ubuntu/tdx/+sourcefiles/edk2/2024.05-2ubuntu0.1+tdx1.0~ppa1/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.debian.tar.xz /buildroot/src/
ADD https://code.launchpad.net/~kobuk-team/+archive/ubuntu/tdx/+sourcefiles/edk2/2024.05-2ubuntu0.1+tdx1.0~ppa1/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.dsc /buildroot/src/
ADD https://code.launchpad.net/~kobuk-team/+archive/ubuntu/tdx/+sourcefiles/edk2/2024.05-2ubuntu0.1+tdx1.0~ppa1/edk2_2024.05.orig.tar.xz /buildroot/src/
RUN dpkg-source -x /buildroot/src/edk2_2024.05-2ubuntu0.1+tdx1.0~ppa1.dsc /buildroot/edk2_build
WORKDIR /buildroot/edk2_build
RUN apt build-dep -y ./
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

### Start sp_vm ###
FROM scratch AS sp_vm
COPY --from=vm_json_builder /output /
### End sp_vm ###
