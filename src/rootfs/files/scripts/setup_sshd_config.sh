#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR
# PROVIDER_CONFIG_DST

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function patch_sshd_config() {
    log_info "patching sshd config";
    sed -i \
        's|[#]*PasswordAuthentication .*|PasswordAuthentication yes|g' \
        "$OUTPUTDIR/etc/ssh/sshd_config";
    sed -i \
        's|[#]*PermitRootLogin .*|PermitRootLogin yes|g' \
        "$OUTPUTDIR/etc/ssh/sshd_config";
    sed -i \
        's|[#]*KbdInteractiveAuthentication .*|KbdInteractiveAuthentication yes|g' \
        "$OUTPUTDIR/etc/ssh/sshd_config";
    sed -i \
        "1 s|^.*$|AuthorizedKeysFile ${PROVIDER_CONFIG_DST}/authorized_keys|" \
        "$OUTPUTDIR/etc/ssh/sshd_config";
}

patch_sshd_config;
