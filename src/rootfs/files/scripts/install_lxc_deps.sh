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

install_deps() {
    EXPECTED_YQ_SHA256="0fb28c6680193c41b364193d0c0fc4a03177aecde51cfc04d506b1517158c2fb"
    wget https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 -O "$OUTPUTDIR/usr/local/bin/yq-go"
    echo "$EXPECTED_YQ_SHA256  $OUTPUTDIR/usr/local/bin/yq-go" | sha256sum -c -
    chmod +x "$OUTPUTDIR/usr/local/bin/yq-go"

    chroot "$OUTPUTDIR" /bin/bash -c "
        set -euo pipefail
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends skopeo umoci jq
    "
}


chroot_init;
install_deps;
chroot_deinit;
