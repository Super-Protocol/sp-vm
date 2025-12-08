#!/bin/bash

# bash unofficial strict mode
set -euo pipefail

# private
BUILDROOT="/buildroot"

# init logging
source "$BUILDROOT/files/scripts/log.sh"

# chroot functions
source "$BUILDROOT/files/scripts/chroot.sh"

function install_openresty() {
    log_info "installing OpenResty and Lua tooling inside VM rootfs"

    # base prerequisites and repo setup
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get update'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get install -y --no-install-recommends wget gnupg ca-certificates lsb-release'

    # add OpenResty APT repository (same logic as in swarm-cloud openresty plugin)
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; wget -O- https://openresty.org/package/pubkey.gpg | apt-key add -'
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; codename=$(lsb_release -sc); echo "deb http://openresty.org/package/ubuntu ${codename} main" > /etc/apt/sources.list.d/openresty.list'

    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get update'

    # install OpenResty and luarocks
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get install -y openresty luarocks'

    # install required Lua modules (best effort – warnings only on failure)
    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; for m in lua-resty-auto-ssl lua-resty-redis lua-resty-http; do echo "[*] installing $m via luarocks"; if ! luarocks install "$m"; then echo "[!] warning: failed to install $m" >&2; fi; done'

    chroot "$OUTPUTDIR" /bin/bash -lc 'set -e; apt-get clean'
}

chroot_init
install_openresty
chroot_deinit


