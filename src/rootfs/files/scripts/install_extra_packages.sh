#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"
KNOT_REPOSITORY="https://pkg.labs.nic.cz/knot-dns"

# package|version|architecture|repository path|SHA-256
KNOT_PACKAGES=(
    "knot|3.5.1-cznic.1~noble|amd64|pool/main/k/knot/knot_3.5.1-cznic.1~noble_amd64.deb|56f9363291705f8d320141182859d658e25f2585848787099e850bb087cb37e4"
    "knot-keymgr|3.5.1-cznic.1~noble|amd64|pool/main/k/knot/knot-keymgr_3.5.1-cznic.1~noble_amd64.deb|0d3eb34b9611b540c80bc4c734a55cfa7551415a8a39ce1155faf6c0fe71a50b"
    "libdnssec10|3.5.1-cznic.1~noble|amd64|pool/main/k/knot/libdnssec10_3.5.1-cznic.1~noble_amd64.deb|7ce01a3e67093eade91745f0fbc27bc8ff32a78ffac4729ad44e43641decff85"
    "libknot16|3.5.1-cznic.1~noble|amd64|pool/main/k/knot/libknot16_3.5.1-cznic.1~noble_amd64.deb|a49b32019c62840a48602fbf57fe1f56139d6eeff618526838a002e22fe6f011"
    "libzscanner5|3.5.1-cznic.1~noble|amd64|pool/main/k/knot/libzscanner5_3.5.1-cznic.1~noble_amd64.deb|ef8981acd1ee8a43a6edccbb3381cf327114d0331abd115044994789fa3c4d00"
)

UBUNTU_PACKAGES=(
    mysql-client
    python3
    python3-pip
    python3-venv
    openssl
    netcat-openbsd
    dnsutils
    curl
    nano
    ncurses-term
    podman
    unzip
    wireguard-tools
    redis-tools
    valkey-tools
    nats-server
    wget
    jq
)

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_extra_packages() {
    log_info "installing Ubuntu system packages"

    chroot "$OUTPUTDIR" apt-get update
    chroot "$OUTPUTDIR" apt-get install -y "${UBUNTU_PACKAGES[@]}"

    # nats-server enables itself by default; Swarm starts it only on nodes in
    # the matching cluster.
    chroot "$OUTPUTDIR" systemctl disable --now nats-server.service 2>/dev/null || true

    # apt installs 87-podman-bridge.conflist into /etc/cni/net.d; move it for kubelet isolation.
    chroot "$OUTPUTDIR" /usr/local/bin/configure-podman-cni.sh
}

function install_s3fs() {
    log_info "installing s3fs"
    chroot "$OUTPUTDIR" apt-get install -y s3fs

    # Required by provider-config-s3fs.service, which mounts /sp for
    # processes running as non-root users.
    if ! grep -qxF 'user_allow_other' "${OUTPUTDIR}/etc/fuse.conf"; then
        printf 'user_allow_other\n' >> "${OUTPUTDIR}/etc/fuse.conf"
    fi
}

function install_knot() {
    local package_spec package version architecture repository_path sha256;
    local filename chroot_path host_path;
    local package_paths=();
    local downloaded_paths=();

    log_info "installing pinned Knot DNS packages"

    for package_spec in "${KNOT_PACKAGES[@]}"; do
        IFS='|' read -r package version architecture repository_path sha256 \
            <<< "$package_spec"
        filename="${repository_path##*/}"
        chroot_path="/tmp/${filename}"
        host_path="${OUTPUTDIR}${chroot_path}"

        log_info "downloading ${package}=${version} (${architecture})"
        wget "${KNOT_REPOSITORY}/${repository_path}" -O "$host_path"
        printf '%s  %s\n' "$sha256" "$host_path" \
            | sha256sum --check --strict -

        package_paths+=("$chroot_path")
        downloaded_paths+=("$host_path")
    done

    chroot "$OUTPUTDIR" apt-get install -y "${package_paths[@]}"
    rm -f "${downloaded_paths[@]}"

    # Swarm starts Knot only on nodes in the matching cluster.
    chroot "$OUTPUTDIR" systemctl disable --now knot.service 2>/dev/null || true
}

chroot_init
install_extra_packages
install_s3fs
install_knot
chroot "$OUTPUTDIR" apt-get clean
chroot_deinit
