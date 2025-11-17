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

### Swarm DB start
FROM golang:1.25.3 AS swarm-db-build
COPY repos/swarm-db /app/swarm/swarm-db
WORKDIR /app/swarm/swarm-db
RUN make
RUN make build-linux-amd64
### Swarm DB finish

### Swarm start
FROM ubuntu:24.04 AS swarm-build

USER root

ARG NODE_VERSION=22.18.0
ENV DEBIAN_FRONTEND=noninteractive
ENV CFG_DIR=/configs
ENV NVM_DIR=/root/.nvm
ENV PATH=$PATH:/root/.nvm/versions/node/v$NODE_VERSION/bin/
ENV NX_DAEMON=false
ENV NX_ADD_PLUGINS=false
ENV NX_NO_CLOUD=true
ENV NODE_OPTIONS=--max_old_space_size=2048

RUN apt-get update
RUN apt-get install -y \
    curl \
    python3 \
    python3-pip \
    python3-venv \
    iproute2 \
    iptables \
    wireguard-tools \
    sqlite3 \
    mysql-client \
    jq

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
RUN . $NVM_DIR/nvm.sh && nvm install $NODE_VERSION && nvm use $NODE_VERSION
RUN npm i -g nx@21.5.2 corepack@latest webpack-cli
RUN curl -fsSL https://get.pnpm.io/install.sh | bash -
RUN corepack enable

WORKDIR /app/swarm

COPY repos/swarm-cloud /app/swarm/swarm-cloud

WORKDIR /app/swarm/swarm-cloud
RUN pnpm install --frozen-lockfile
RUN pnpm nx build swarm-cloud-api --skip-nx-cache --output-style=stream --verbose
RUN pnpm nx build swarm-node --skip-nx-cache --output-style=stream --verbose
# build provision-plugin-sdk wheel for reuse (use venv to avoid PEP 668 restrictions)
RUN python3 -m venv /tmp/pvenv \
 && /tmp/pvenv/bin/pip install --no-cache-dir build wheel \
 && bash -lc 'cd /app/swarm/swarm-cloud/services/provision-plugin-sdk && /tmp/pvenv/bin/python -m build --wheel --outdir /tmp/provision-wheels' \
 && ls -l /tmp/provision-wheels
### Swarm finish

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

# RKE2: clean default installation inside rootfs (no legacy scripts)
ARG RKE2_VERSION=v1.32.8+rke2r1
ENV INSTALL_RKE2_VERSION=${RKE2_VERSION}
RUN chroot ${OUTPUTDIR} /bin/sh -c 'curl -sfL https://get.rke2.io | sh -' \
 && chroot ${OUTPUTDIR} /bin/sh -c 'systemctl disable rke2-server.service' \
 && chroot ${OUTPUTDIR} /bin/sh -c 'systemctl disable rke2-agent.service'
# Ensure kubectl exists in VM rootfs where we expect it
RUN mkdir -p "${OUTPUTDIR}/var/lib/rancher/rke2/bin" \
 && bash -lc 'set -e; \
   if [ -x "${OUTPUTDIR}/var/lib/rancher/rke2/bin/kubectl" ]; then \
     echo "kubectl already present in rke2 bin"; \
   elif [ -x "${OUTPUTDIR}/usr/local/bin/kubectl" ]; then \
     cp "${OUTPUTDIR}/usr/local/bin/kubectl" "${OUTPUTDIR}/var/lib/rancher/rke2/bin/kubectl"; \
     chmod +x "${OUTPUTDIR}/var/lib/rancher/rke2/bin/kubectl"; \
   else \
     echo "kubectl not found at expected locations; continuing"; \
   fi'

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
# ADD rootfs/files/configs/cert/superprotocol-certs.sh ${OUTPUTDIR}/usr/local/bin/
# ADD rootfs/files/configs/cert/superprotocol-certs.service ${OUTPUTDIR}/etc/systemd/system
# RUN ln -s /etc/systemd/system/superprotocol-certs.service ${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/superprotocol-certs.service
ADD rootfs/files/scripts/refresh_ca_certs.sh /buildroot/files/scripts/refresh_ca_certs.sh
RUN --security=insecure /buildroot/files/scripts/refresh_ca_certs.sh

# check for presence of trusted self-signed CA from Super Protocol
RUN awk -v cmd='openssl x509 -noout -subject' '/BEGIN/{close(cmd)};{print | cmd}' < ${OUTPUTDIR}/etc/ssl/certs/ca-certificates.crt | grep -i 'super'

ARG SUPER_REGISTRY_HOST=registry.superprotocol.local
RUN echo "127.0.0.1 $SUPER_REGISTRY_HOST $LOCAL_REGISTRY_HOST" >> "${OUTPUTDIR}/etc/hosts"
RUN echo "sp-$(petname)" > "${OUTPUTDIR}/etc/hostname"
RUN mkdir -p "${OUTPUTDIR}/var/lib/etc-rancher/node"
RUN LC_ALL=C tr -dc '[:alpha:][:digit:]' < /dev/urandom | head -c 32 > "${OUTPUTDIR}/var/lib/etc-rancher/node/password"
ADD rootfs/files/configs/etc/cni/net.d/05-cilium.conflist ${OUTPUTDIR}/etc/cni/net.d/05-cilium.conflist
ADD rootfs/files/configs/etc/sysctl.d/99-zzz-override_cilium.conf ${OUTPUTDIR}/etc/sysctl.d/99-zzz-override_cilium.conf
ADD rootfs/files/configs/etc/resolv.conf ${OUTPUTDIR}/etc/resolv.conf

# copy iscsi configs, cause this partition will be remounted with empty dir
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
COPY --from=ghcr.io/super-protocol/tee-pki-authority-service-lxc:build-18472436269 /pki-authority.tar "${OUTPUTDIR}/root/containers/pki-authority.tar"
ADD rootfs/files/configs/pki-service/lxc-template.yaml "${OUTPUTDIR}/root/containers/lxc-template.yaml"
ADD rootfs/files/configs/pki-service/dnsmasq.conf "${OUTPUTDIR}/etc/lxc/dnsmasq.conf"
ADD rootfs/files/configs/pki-service/lxc-net "${OUTPUTDIR}/etc/default/lxc-net"
RUN --security=insecure /buildroot/files/scripts/install_lxc_deps.sh

ADD rootfs/files/configs/etc/multipath.conf.append /buildroot/files/configs/etc/multipath.conf.append
ADD rootfs/files/configs/etc/sysctl.conf.append /buildroot/files/configs/etc/sysctl.conf.append

RUN mkdir -p "${OUTPUTDIR}/sp"
ADD rootfs/files/configs/etc/systemd/system/check-config-files.service ${OUTPUTDIR}/etc/systemd/system/check-config-files.service
ADD rootfs/files/configs/etc/systemd/system/check-config-files.timer ${OUTPUTDIR}/etc/systemd/system/check-config-files.timer
ADD rootfs/files/configs/usr/local/bin/check-config-files.sh ${OUTPUTDIR}/usr/local/bin/check-config-files.sh
# Enable only the timer; service will be triggered by it
RUN ln -sf /etc/systemd/system/check-config-files.timer "${OUTPUTDIR}/etc/systemd/system/timers.target.wants/check-config-files.timer"
ADD rootfs/files/configs/etc/systemd/system/local-registry.service ${OUTPUTDIR}/etc/systemd/system/local-registry.service
ADD rootfs/files/configs/usr/local/bin/local-registry.sh ${OUTPUTDIR}/usr/local/bin/local-registry.sh
RUN ln -sf /etc/systemd/system/local-registry.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/local-registry.service"
ADD rootfs/files/configs/etc/systemd/system/hardening-vm.service ${OUTPUTDIR}/etc/systemd/system/hardening-vm.service
ADD rootfs/files/configs/usr/local/bin/hardening-vm.sh ${OUTPUTDIR}/usr/local/bin/hardening-vm.sh
RUN ln -sf /etc/systemd/system/hardening-vm.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/hardening-vm.service"

# swarm services
ADD rootfs/files/configs/etc/systemd/system/swarm-db.service ${OUTPUTDIR}/etc/systemd/system/swarm-db.service
RUN ln -sf /etc/systemd/system/swarm-db.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-db.service"
ADD rootfs/files/configs/etc/systemd/system/swarm-cloud-api.service ${OUTPUTDIR}/etc/systemd/system/swarm-cloud-api.service
ADD rootfs/files/configs/usr/local/bin/swarm-cloud-api.sh ${OUTPUTDIR}/usr/local/bin/swarm-cloud-api.sh
# RUN ln -sf /etc/systemd/system/swarm-cloud-api.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-cloud-api.service"
ADD rootfs/files/configs/etc/systemd/system/swarm-node.service ${OUTPUTDIR}/etc/systemd/system/swarm-node.service
ADD rootfs/files/configs/usr/local/bin/swarm-node.sh ${OUTPUTDIR}/usr/local/bin/swarm-node.sh
RUN ln -sf /etc/systemd/system/swarm-node.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/swarm-node.service"
RUN chmod +x ${OUTPUTDIR}/usr/local/bin/swarm-cloud-api.sh ${OUTPUTDIR}/usr/local/bin/swarm-node.sh
# run-state directories are prepared in state_disk_mount.sh; bind mounts via fstab
ADD rootfs/files/configs/etc/securetty "${OUTPUTDIR}/etc/securetty"
# ensure bind mount targets exist on read-only rootfs
RUN mkdir -p "${OUTPUTDIR}/etc/kubernetes"

# disabling serial getty (mask instance)
RUN ln -sf /dev/null "${OUTPUTDIR}/etc/systemd/system/getty@ttyS0.service"

# swarm binaries into VM rootfs
RUN mkdir -p "${OUTPUTDIR}/etc/swarm-db" "${OUTPUTDIR}/etc/swarm-cloud"
COPY --from=swarm-db-build /app/swarm/swarm-db/swarm-db-linux-amd64 ${OUTPUTDIR}/etc/swarm-db/swarm-db-linux-amd64
COPY --from=swarm-build /app/swarm/swarm-cloud ${OUTPUTDIR}/etc/swarm-cloud
RUN chmod +x ${OUTPUTDIR}/etc/swarm-db/swarm-db-linux-amd64
ARG NODE_VERSION=22.18.0
COPY --from=swarm-build /root/.nvm/versions/node/v${NODE_VERSION}/bin/node ${OUTPUTDIR}/usr/local/bin/node

# ensure service scripts are executable in VM rootfs
RUN mkdir -p "${OUTPUTDIR}/var/lib/etc-wireguard" \
 && rm -rf "${OUTPUTDIR}/etc/wireguard" \
 && ln -s /var/lib/etc-wireguard "${OUTPUTDIR}/etc/wireguard"

RUN mkdir -p "${OUTPUTDIR}/var/lib/etc-rancher" \
 && rm -rf "${OUTPUTDIR}/etc/rancher" \
 && mkdir -p "${OUTPUTDIR}/etc/rancher"

# tools needed at runtime
RUN chroot ${OUTPUTDIR} /usr/bin/apt-get update \
 && chroot ${OUTPUTDIR} /usr/bin/apt-get install -y --no-install-recommends mysql-client python3 python3-pip \
 && chroot ${OUTPUTDIR} /usr/bin/apt-get clean \
 && rm -rf ${OUTPUTDIR}/var/lib/apt/lists/*

# install provision-plugin-sdk into VM python environment (from prebuilt wheel)
COPY --from=swarm-build /tmp/provision-wheels ${OUTPUTDIR}/opt/provision-wheels
RUN chroot ${OUTPUTDIR} /bin/bash -lc 'shopt -s nullglob; set -e; files=(/opt/provision-wheels/*.whl); \
  if (( ${#files[@]} )); then \
    python3 -m pip install --break-system-packages "${files[@]}"; \
  else \
    echo "No wheels found, installing from source"; \
    python3 -m pip install --break-system-packages /etc/swarm-cloud/services/provision-plugin-sdk; \
  fi'

# Build info
ARG SP_VM_IMAGE_VERSION
RUN bash -c '[[ -n "$SP_VM_IMAGE_VERSION" ]] && echo "$SP_VM_IMAGE_VERSION" > "${OUTPUTDIR}/etc/sp-release"'

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
RUN apt-get update && apt-get -y -o Acquire::Retries=3 build-dep ./
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

#### swarm
COPY --from=swarm-db-build /app/swarm/swarm-db/swarm-db-linux-amd64 /etc/swarm-db/swarm-db-linux-amd64
COPY --from=swarm-build /app/swarm/swarm-cloud /etc/swarm-cloud
COPY --from=swarm-build /tmp/provision-wheels /artifacts/provision-wheels
### End sp_vm ###

EXPOSE 8001
EXPOSE 7946
EXPOSE 3000
EXPOSE 32768-60999
