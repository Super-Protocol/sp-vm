#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR
# SOURCE_DATE_EPOCH

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function cleanup_rootfs() {
    log_info "cleaning up rootfs";
    rm -rf "${OUTPUTDIR}/kernel_deb";
    # best-effort removal of heavy toolchain packages only; keep core dev libs (libc6-dev, linux-libc-dev, etc.)
    # so that OpenResty and other components depending on them continue to work.
    chroot "$OUTPUTDIR" /bin/bash -c \
        'kernel_headers="$(dpkg-query -W -f="${binary:Package}\n" "linux-headers-*-nvidia-gpu-confidential" 2>/dev/null || true)"; \
        dpkg -r \
            build-essential \
            g++-13 \
            g++-13-x86-64-linux-gnu \
            g++-x86-64-linux-gnu \
            g++ \
            gcc \
            $kernel_headers';

    # Preserve the final package inventory outside rootfs before /var/lib is
    # removed. The export stage uses it as a diagnostic manifest.
    local package_format="\${binary:Package}\t\${Version}\t\${Architecture}\n";
    chroot "$OUTPUTDIR" dpkg-query -W \
        --showformat="$package_format" \
        | LC_ALL=C sort > "$BUILDROOT/rootfs-packages.manifest";

    rm -rf "${OUTPUTDIR}"/tmp/*;
    rm -rf "${OUTPUTDIR}"/usr/share/{bash-completion,bug,doc,info,lintian,locale,man,menu,misc,pixmaps,zsh};
    find "${OUTPUTDIR}/var/run" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; || true;
    rm -rf "${OUTPUTDIR}"/var/{cache,lib,log,tmp};
    rm -f "${OUTPUTDIR}/etc/systemd/system/sshd.service"
    rm -f "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/ssh.service"
    rm -f "${OUTPUTDIR}/etc/systemd/system/sockets.target.wants/ssh.socket"
    rm -f "${OUTPUTDIR}/etc/systemd/system/ssh.service.requires/ssh.socket"
    # Keep serial console for debugging
    # rm -f "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

    # Package installation and DKMS builds recreate machine-specific state.
    # Remove it again at the final rootfs boundary.
    rm -f "${OUTPUTDIR}"/etc/ssh/ssh_host_*_key*;
    : > "${OUTPUTDIR}/etc/machine-id";
    rm -f "${OUTPUTDIR}/var/lib/systemd/random-seed";
    rm -rf "${OUTPUTDIR}/root/.cache" "${OUTPUTDIR}/root/.npm";
    find "${OUTPUTDIR}/run" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true;

}

function normalize_rootfs() {
    log_info "normalizing final rootfs";

    # useradd records the current day in /etc/shadow. Locked system accounts do
    # not use this field for password expiry, so pin it to the snapshot day.
    local shadow_tmp="${OUTPUTDIR}/etc/shadow.reproducible";
    local snapshot_day="$(( SOURCE_DATE_EPOCH / 86400 ))";
    awk -F: -v OFS=: -v snapshot_day="$snapshot_day" \
        '$2 ~ /^[!*]/ {$3 = snapshot_day} {print}' \
        "${OUTPUTDIR}/etc/shadow" > "$shadow_tmp";
    chown --reference="${OUTPUTDIR}/etc/shadow" "$shadow_tmp";
    chmod --reference="${OUTPUTDIR}/etc/shadow" "$shadow_tmp";
    mv "$shadow_tmp" "${OUTPUTDIR}/etc/shadow";

    # This is the single timestamp-normalization boundary for the complete
    # logical rootfs. No rootfs mutations may be added after this step.
    find "$OUTPUTDIR" -xdev -depth \
        -exec touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" {} +;
}

cleanup_rootfs;
normalize_rootfs;
