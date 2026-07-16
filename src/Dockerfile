# syntax=docker/dockerfile:1-labs@sha256:7d49dad25a050e14338ba7028b0460243f9d911dedc160a8fe20c34738fef3af

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
        wget gcc make build-essential debootstrap gettext \
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

### Start low-level release assets ###
FROM rootfs_base AS low_level_release_download
ARG LOW_LEVEL_RELEASE=sp-vm-low-level-v1
ARG LOW_LEVEL_SHA256SUMS=71c28b3260dddfc1506521034c4fdd69686a88813e3861681a2089c448edbf8a
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eu; \
    [[ "$LOW_LEVEL_RELEASE" =~ ^sp-vm-low-level-v[0-9]+$ ]] \
        || { echo "Invalid LOW_LEVEL_RELEASE: $LOW_LEVEL_RELEASE" >&2; exit 1; }; \
    [[ "$LOW_LEVEL_SHA256SUMS" =~ ^[0-9a-f]{64}$ ]] \
        || { echo "LOW_LEVEL_SHA256SUMS must contain the pinned SHA-256 of SHA256SUMS" >&2; exit 1; }; \
    base_url="https://github.com/Super-Protocol/sp-vm/releases/download/${LOW_LEVEL_RELEASE}"; \
    mkdir -p /low-level-release; \
    cd /low-level-release; \
    wget --https-only --output-document=SHA256SUMS "${base_url}/SHA256SUMS"; \
    printf '%s  %s\n' "$LOW_LEVEL_SHA256SUMS" SHA256SUMS | sha256sum --check -; \
    while read -r checksum filename extra; do \
        [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] && [[ -z "${extra:-}" ]] \
            || { echo "Invalid SHA256SUMS entry" >&2; exit 1; }; \
        case "$filename" in \
            vmlinuz|OVMF.fd|OVMF_AMD.fd|OVMF_TDX.fd|*.deb) ;; \
            *) echo "Unexpected low-level asset in SHA256SUMS: $filename" >&2; exit 1 ;; \
        esac; \
        wget --https-only --output-document="$filename" "${base_url}/${filename}"; \
    done < SHA256SUMS; \
    sha256sum --check SHA256SUMS

# A named BuildKit context called low_level_assets overrides this stage and may
# point directly to a flat local low-level export directory.
FROM scratch AS low_level_assets
COPY --from=low_level_release_download /low-level-release/ /

FROM rootfs_base AS low_level_assets_validated
COPY --from=low_level_assets / /low-level/
RUN set -eu; \
    test -s /low-level/vmlinuz; \
    test -s /low-level/OVMF.fd; \
    test -s /low-level/OVMF_AMD.fd; \
    test -s /low-level/OVMF_TDX.fd; \
    test -n "$(find /low-level -maxdepth 1 -type f -name 'linux-image*.deb' -print -quit)"; \
    unexpected="$(find /low-level -mindepth 1 ! -type f -print -quit)"; \
    test -z "$unexpected" \
        || { echo "Low-level export must be flat, found: $unexpected" >&2; exit 1; }
### End low-level release assets ###

FROM rootfs_base AS rootfs_builder

COPY --from=low_level_assets_validated /low-level/*.deb ${OUTPUTDIR}/kernel_deb/
ADD rootfs/files/scripts/install_kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/install_kernel.sh

ADD general/files/scripts/chroot.sh /buildroot/files/scripts/
ADD rootfs/files/scripts/install_nvidia.sh /buildroot/files/scripts/
RUN --security=insecure /buildroot/files/scripts/install_nvidia.sh
ADD rootfs/files/scripts/install_gve.sh /buildroot/files/scripts/install_gve.sh
RUN --security=insecure /buildroot/files/scripts/install_gve.sh

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

RUN printf 'sp-vm\n' > "${OUTPUTDIR}/etc/hostname"
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
RUN --security=insecure /buildroot/files/scripts/install_pccs.sh
ADD rootfs/files/configs/pki-service/sgx_default_qcnl.conf ${OUTPUTDIR}/etc/sgx_default_qcnl.conf
RUN mkdir -p "${OUTPUTDIR}/etc/systemd/system/pccs.service.d"
ADD rootfs/files/configs/pccs/10-generate-keys.conf "${OUTPUTDIR}/etc/systemd/system/pccs.service.d/10-generate-keys.conf"
ADD rootfs/files/configs/pccs/pccs-generate-keys.sh "${OUTPUTDIR}/usr/local/bin/pccs-generate-keys.sh"
RUN chmod 0755 "${OUTPUTDIR}/usr/local/bin/pccs-generate-keys.sh"

# Custom swarm services
RUN mkdir -p ${OUTPUTDIR}/etc/swarm-services/

# Prevent package installation from starting daemons inside the chroot
ADD rootfs/files/scripts/setup_runtime_tools.sh /buildroot/files/scripts/
RUN chmod +x /buildroot/files/scripts/setup_runtime_tools.sh
RUN --security=insecure /buildroot/files/scripts/setup_runtime_tools.sh

# System packages used by VM services and provision plugins
ADD rootfs/files/configs/etc/dpkg/dpkg.cfg.d/force-confold ${OUTPUTDIR}/etc/dpkg/dpkg.cfg.d/force-confold
ADD rootfs/files/scripts/install_extra_packages.sh /buildroot/files/scripts/
RUN --security=insecure bash /buildroot/files/scripts/install_extra_packages.sh

# install PKI npm components globally
ARG PKI_SYNC_CLIENT_VERSION=5.0.9
ARG PKI_CERT_GENERATOR_VERSION=5.0.4
ARG PKI_VM_MEASUREMENTS_VERSION=1.0.5
ADD rootfs/files/scripts/install_pki_components.sh /buildroot/files/scripts/
RUN chmod +x /buildroot/files/scripts/install_pki_components.sh
RUN --security=insecure /buildroot/files/scripts/install_pki_components.sh \
    "${PKI_SYNC_CLIENT_VERSION}" "${PKI_CERT_GENERATOR_VERSION}" "${PKI_VM_MEASUREMENTS_VERSION}"

# Python runtime dependencies used by Swarm services and provision plugins
ADD rootfs/files/configs/python/requirements.lock /buildroot/files/configs/python/requirements.lock
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

### Start logical rootfs reproducibility export ###
FROM rootfs_builder AS rootfs_artifact
ADD rootfs/files/scripts/export_base_system.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/export_base_system.sh

FROM scratch AS rootfs_export
COPY --from=rootfs_artifact /output/rootfs-artifacts/ /
### End logical rootfs reproducibility export ###

### Start image ###
FROM ubuntu:noble-20250714@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061 AS image_builder
ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT_ID=20260714T000000Z
ARG SOURCE_DATE_EPOCH=1783987200
ARG ROOTFS_UUID=9d8ae77c-0f99-4b4c-a919-0de57b426ced
ARG ROOTFS_DIR_HASH_SEED=7ebf1975-28bf-544d-948f-5bb483eff52e
ARG ROOTFS_VERITY_UUID=0ff7f592-c526-46f7-83d5-f47ad3f69e89
ARG ROOTFS_VERITY_SALT=7ebf197528bf544d348f5bb483eff52ea41e0f99dac93882965f65924d1f87a6
ARG BOOT_UUID=53e6f641-37c0-46d2-a729-7d9f49fcf589
ARG BOOT_DIR_HASH_SEED=696833d7-b1d1-4f05-8ede-1a62f2e0a70d
ARG ESP_VOLUME_ID=A1B2C3D4
ARG DISK_GUID=6f873c23-1b65-4b5c-8e67-8f4f3c3419a1
ARG BOOT_PART_GUID=4389386d-d949-4b54-942d-3f6b1148c8d1
ARG BIOS_PART_GUID=f4958893-2686-4bca-8251-1499197a2774
ARG ESP_PART_GUID=58f79298-702d-4a8b-b53c-73a76da19e77
ARG ROOTFS_PART_GUID=ec6a4d3f-0f19-47df-9c1f-8f221bbf175b
ARG ROOTFS_HASH_PART_GUID=672b89b6-76c3-45a5-af55-0a401f2d5a6f
RUN rm -f /etc/apt/sources.list.d/ubuntu.sources \
    && printf 'deb http://archive.ubuntu.com/ubuntu/ noble main\n' > /etc/apt/sources.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates \
    && printf 'deb https://snapshot.ubuntu.com/ubuntu/%s/ noble main universe\n' \
        "$UBUNTU_SNAPSHOT_ID" \
        > /etc/apt/sources.list \
    && printf 'deb https://snapshot.ubuntu.com/ubuntu/%s/ noble-updates main universe\n' \
        "$UBUNTU_SNAPSHOT_ID" \
        >> /etc/apt/sources.list \
    && printf 'deb https://snapshot.ubuntu.com/ubuntu/%s/ noble-security main universe\n' \
        "$UBUNTU_SNAPSHOT_ID" \
        >> /etc/apt/sources.list \
    && printf 'Acquire::Languages "none";\n' > /etc/apt/apt.conf.d/50snapshot \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        cryptsetup-bin dosfstools e2fsprogs faketime gdisk gettext-base \
        grub-pc-bin grub-efi-amd64-bin grub2-common kpartx mtools util-linux \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

# is required by passing build arg, value example: SP_VM_IMAGE_VERSION=build-1
ARG SP_VM_IMAGE_VERSION

WORKDIR /output
ADD general/files/scripts/log.sh /buildroot/files/scripts/

ADD image/files/scripts/create_image.sh /buildroot/files/scripts/
ADD image/files/scripts/create_rootfs_verity.sh /buildroot/files/scripts/
ADD image/files/configs/grub.cfg.tmpl /buildroot/files/configs/
RUN --mount=type=bind,target=/output/rootfs,readonly,from=rootfs_builder,source=/output/rootfs --security=insecure \
    /buildroot/files/scripts/create_image.sh
### End image ###

### Start vm_json_builder ###
FROM ubuntu:noble-20250714@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061 AS vm_json_builder
ARG SP_VM_IMAGE_VERSION
ARG S3_BUCKET
COPY --from=image_builder /output /output
COPY --from=low_level_assets_validated /low-level/OVMF_AMD.fd /output/OVMF_AMD.fd
COPY --from=low_level_assets_validated /low-level/OVMF.fd /output/OVMF.fd
COPY --from=low_level_assets_validated /low-level/OVMF_TDX.fd /output/OVMF_TDX.fd
COPY --from=low_level_assets_validated /low-level/vmlinuz /output/vmlinuz
ADD bundle/files/scripts/generate_vm_json.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/generate_vm_json.sh
### End vm_json_builder ###


### Start sp_vm ###
FROM scratch AS sp_vm
COPY --from=vm_json_builder /output /
### End sp_vm ###
