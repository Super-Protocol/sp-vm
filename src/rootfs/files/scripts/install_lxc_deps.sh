#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init loggggging;
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

install_deps() {
    EXPECTED_YQ_SHA256="0fb28c6680193c41b364193d0c0fc4a03177aecde51cfc04d506b1517158c2fb"
    wget https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 -O "${OUTPUTDIR}/usr/local/bin/yq-go"
    echo "${EXPECTED_YQ_SHA256}  ${OUTPUTDIR}/usr/local/bin/yq-go" | sha256sum -c -
    chmod +x "${OUTPUTDIR}/usr/local/bin/yq-go"

    chroot "${OUTPUTDIR}" /bin/bash -c "
        set -euo pipefail
        for i in {1..5}; do
            apt -o Acquire::Retries=5 update && break;
            echo 'apt update failed, retrying...'; sleep 5;
        done
        DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends --fix-missing \
            -o Acquire::Retries=5 -o Acquire::http::Timeout=30 \
            install skopeo umoci jq
    "
}

chroot_init;
install_deps;
chroot_deinit;
