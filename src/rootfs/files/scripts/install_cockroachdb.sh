#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_cockroachdb() {
    log_info "installing CockroachDB binary inside VM rootfs"

    # Ensure required tools are present
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get update'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get install -y --no-install-recommends wget ca-certificates tar'

    # Download and install latest CockroachDB binary
    chroot "$OUTPUTDIR" /bin/bash -lc '
        set -e;
        arch=$(uname -m);
        case "$arch" in
          x86_64) cr_arch=amd64 ;;
          aarch64|arm64) cr_arch=arm64 ;;
          *) cr_arch=amd64 ;;
        esac;
        cd /tmp;
        wget -q https://binaries.cockroachdb.com/cockroach-latest.linux-${cr_arch}.tgz -O cockroach.tgz;
        tar -xzf cockroach.tgz;
        dir=$(tar -tzf cockroach.tgz | head -1 | cut -d/ -f1);
        cp "$dir/cockroach" /usr/local/bin/cockroach;
        chmod 0755 /usr/local/bin/cockroach;
        rm -rf "$dir" cockroach.tgz;
    '

    chroot "$OUTPUTDIR" /bin/bash -lc 'apt-get clean'
}

chroot_init
install_cockroachdb
chroot_deinit
