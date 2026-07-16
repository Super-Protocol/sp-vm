#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function install_kernel() {
    mapfile -t kernel_debs < <(
        find "$OUTPUTDIR/kernel_deb" \
            -maxdepth 1 \
            -type f \
            -name 'linux-image*.deb' \
            -print
    );
    if [[ "${#kernel_debs[@]}" -ne 1 ]]; then
        log_fail "expected exactly one linux-image DEB, found ${#kernel_debs[@]}";
    fi

    kernel_package="$(dpkg-deb --field "${kernel_debs[0]}" Package)";
    KERNEL_RELEASE="${kernel_package#linux-image-}";
    if [[ -z "$KERNEL_RELEASE" || "$KERNEL_RELEASE" = "$kernel_package" ]]; then
        log_fail "invalid kernel package name: $kernel_package";
    fi

    log_info "installing kernel to rootfs";
    chroot "$OUTPUTDIR" /bin/bash -c '/usr/bin/dpkg -i /kernel_deb/*.deb';
    status_format="\${db:Status-Abbrev}";
    test "$(chroot "$OUTPUTDIR" dpkg-query -W -f="$status_format" "$kernel_package")" = "ii ";

    printf '%s\n' "$KERNEL_RELEASE" > "$BUILDROOT/kernel-release";
    log_info "installed kernel release: $KERNEL_RELEASE";
}

install_kernel;
