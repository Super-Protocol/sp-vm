#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# VERSION_CODENAME
# OUTPUTDIR
# UBUNTU_SNAPSHOT_ID
# SOURCE_DATE_EPOCH

# private
BUILDROOT="/buildroot";
TARGET_ARCH="amd64";

BASE_PACKAGES="init,openssh-server,netplan.io,curl,htop,open-iscsi,cryptsetup,ca-certificates,gnupg2,kmod,gcc-13,build-essential,chrony,iptables,dbus,cryptsetup-bin,e2fsprogs,gettext,wireguard"

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function validate_reproducibility_inputs() {
    if [[ ! "$UBUNTU_SNAPSHOT_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
        log_fail "UBUNTU_SNAPSHOT_ID must use the YYYYMMDDTHHMMSSZ format";
        return 1;
    fi

    local snapshot_date;
    snapshot_date="${UBUNTU_SNAPSHOT_ID:0:4}-${UBUNTU_SNAPSHOT_ID:4:2}-${UBUNTU_SNAPSHOT_ID:6:2} ${UBUNTU_SNAPSHOT_ID:9:2}:${UBUNTU_SNAPSHOT_ID:11:2}:${UBUNTU_SNAPSHOT_ID:13:2} UTC";

    local calculated_epoch;
    calculated_epoch="$(date -u --date="$snapshot_date" +%s)" \
        || log_fail "failed to convert UBUNTU_SNAPSHOT_ID to epoch";

    if [[ "$calculated_epoch" != "$SOURCE_DATE_EPOCH" ]]; then
        log_fail "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH does not match UBUNTU_SNAPSHOT_ID=$UBUNTU_SNAPSHOT_ID (expected $calculated_epoch)";
        return 1;
    fi
}

function configure_snapshot_sources() {
    log_info "configuring Ubuntu snapshot $UBUNTU_SNAPSHOT_ID";

    rm -f "${OUTPUTDIR}/etc/apt/sources.list.d/ubuntu.sources";
    cat > "${OUTPUTDIR}/etc/apt/sources.list" <<EOF
deb http://archive.ubuntu.com/ubuntu/ ${VERSION_CODENAME} main universe
deb http://archive.ubuntu.com/ubuntu/ ${VERSION_CODENAME}-updates main universe
deb http://security.ubuntu.com/ubuntu/ ${VERSION_CODENAME}-security main universe
EOF

    cat > "${OUTPUTDIR}/etc/apt/apt.conf.d/50snapshot" <<EOF
APT::Snapshot "${UBUNTU_SNAPSHOT_ID}";
APT::Get::Always-Include-Phased-Updates "true";
Acquire::Languages "none";
EOF
}

function apply_snapshot_updates() {
    log_info "applying release, updates, and security packages from the pinned snapshot";

    cat > "${OUTPUTDIR}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 "${OUTPUTDIR}/usr/sbin/policy-rc.d";

    chroot "$OUTPUTDIR" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        TZ=UTC \
        apt-get update;
    chroot "$OUTPUTDIR" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        TZ=UTC \
        apt-get dist-upgrade -y -o APT::Install-Recommends=false;
    chroot "$OUTPUTDIR" apt-get clean;

    rm -f "${OUTPUTDIR}/usr/sbin/policy-rc.d";
}

function sanitize_generated_state() {
    log_info "removing build-time identities, keys, logs, and caches";

    # Host keys must be unique per VM. Generate missing keys when ssh.service starts.
    rm -f "${OUTPUTDIR}"/etc/ssh/ssh_host_*_key*;
    install -d -m 0755 "${OUTPUTDIR}/etc/systemd/system/ssh.service.d";
    cat > "${OUTPUTDIR}/etc/systemd/system/ssh.service.d/10-generate-host-keys.conf" <<'EOF'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF

    : > "${OUTPUTDIR}/etc/machine-id";
    rm -f "${OUTPUTDIR}/var/lib/dbus/machine-id";
    install -d -m 0755 "${OUTPUTDIR}/var/lib/dbus";
    ln -s /etc/machine-id "${OUTPUTDIR}/var/lib/dbus/machine-id";

    # open-iscsi generates a random initiator IQN in its post-install script.
    # Defer it to iscsid's first startup so cloned VMs do not share an identity.
    cat > "${OUTPUTDIR}/etc/iscsi/initiatorname.iscsi" <<'EOF'
## Generated uniquely when iscsid starts for the first time.
GenerateName=yes
EOF
    chmod 0600 "${OUTPUTDIR}/etc/iscsi/initiatorname.iscsi";

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

    find "${OUTPUTDIR}/var/log" -type f -exec truncate --size=0 {} +;
    rm -f "${OUTPUTDIR}/var/lib/systemd/random-seed";
    rm -rf "${OUTPUTDIR}/tmp"/*;
    rm -rf "${OUTPUTDIR}/var/tmp"/*;
    rm -rf "${OUTPUTDIR}/var/cache/apt/archives"/*.deb;
    # ldconfig's auxiliary cache embeds filesystem-specific stat data. It is
    # optional and will be recreated by ldconfig when packages change.
    rm -f "${OUTPUTDIR}/var/cache/ldconfig/aux-cache";

    printf 'sp-vm\n' > "${OUTPUTDIR}/etc/hostname";

    # debootstrap copies the builder resolver configuration. Replace it with
    # the repository-owned configuration before normalizing timestamps.
    install -m 0644 \
        "$BUILDROOT/files/configs/etc/resolv.conf" \
        "${OUTPUTDIR}/etc/resolv.conf";
}

function normalize_timestamps() {
    log_info "normalizing rootfs mtimes to SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH";
    find "$OUTPUTDIR" -xdev -depth \
        -exec touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" {} +;
}

function create_base_system() {
    log_info "creating base system";
    if ! debootstrap \
        "--arch=$TARGET_ARCH" \
        --variant=minbase \
        "--include=$BASE_PACKAGES" \
        --components=main,universe \
        "$VERSION_CODENAME" \
        "$OUTPUTDIR" \
        "https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT_ID}/"; then
        if [[ -f "${OUTPUTDIR}/debootstrap/debootstrap.log" ]]; then
            tail -n 100 "${OUTPUTDIR}/debootstrap/debootstrap.log" >&2;
        fi
        log_fail "failed to create base system";
        return 1;
    fi

    configure_snapshot_sources;
    apply_snapshot_updates;
    sanitize_generated_state;
    normalize_timestamps;
}

validate_reproducibility_inputs;
create_base_system;
