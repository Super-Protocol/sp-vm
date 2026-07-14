#!/bin/bash

set -euo pipefail

# public, required
# OUTPUTDIR
# OUTPUTROOT
# VERSION_CODENAME
# UBUNTU_SNAPSHOT_ID
# SOURCE_DATE_EPOCH

ARTIFACT_DIR="${OUTPUTROOT}/rootfs-base-artifacts"

function verify_base_system() {
    grep -Fxq "APT::Snapshot \"${UBUNTU_SNAPSHOT_ID}\";" \
        "${OUTPUTDIR}/etc/apt/apt.conf.d/50snapshot"
    grep -Fxq "deb http://archive.ubuntu.com/ubuntu/ ${VERSION_CODENAME} main universe" \
        "${OUTPUTDIR}/etc/apt/sources.list"
    grep -Fxq "deb http://archive.ubuntu.com/ubuntu/ ${VERSION_CODENAME}-updates main universe" \
        "${OUTPUTDIR}/etc/apt/sources.list"
    grep -Fxq "deb http://security.ubuntu.com/ubuntu/ ${VERSION_CODENAME}-security main universe" \
        "${OUTPUTDIR}/etc/apt/sources.list"

    if [[ -n "$(find "${OUTPUTDIR}/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*_key*' -print -quit)" ]]; then
        echo "rootfs contains generated SSH host keys" >&2
        return 1
    fi
    test ! -s "${OUTPUTDIR}/etc/machine-id"
    grep -Fxq "GenerateName=yes" \
        "${OUTPUTDIR}/etc/iscsi/initiatorname.iscsi"
    grep -Fxq "ExecStartPre=/usr/bin/ssh-keygen -A" \
        "${OUTPUTDIR}/etc/systemd/system/ssh.service.d/10-generate-host-keys.conf"
    grep -Fxq "ExecStartPre=/usr/sbin/sshd -t" \
        "${OUTPUTDIR}/etc/systemd/system/ssh.service.d/10-generate-host-keys.conf"

    local bad_mtimes
    bad_mtimes="$(find "$OUTPUTDIR" -xdev -printf '%T@ %p\n' | \
        awk -v expected="$SOURCE_DATE_EPOCH" '$1 != expected {print}')"
    if [[ -n "$bad_mtimes" ]]; then
        echo "rootfs contains mtimes different from SOURCE_DATE_EPOCH:" >&2
        echo "$bad_mtimes" | sed -n '1,20p' >&2
        return 1
    fi
}

function write_metadata_manifest() {
    (
        cd "$OUTPUTDIR"
        find . -xdev -print0 \
            | LC_ALL=C sort -z \
            | xargs -0r stat --printf='%F\t%a\t%u\t%g\t%s\t%Y\t%n\n' --
    ) > "$ARTIFACT_DIR/rootfs.metadata"

    (
        cd "$OUTPUTDIR"
        find . -xdev -type f -print0 \
            | LC_ALL=C sort -z \
            | xargs -0r sha256sum --
    ) > "$ARTIFACT_DIR/rootfs.files.sha256"

    (
        cd "$OUTPUTDIR"
        find . -xdev -type l -printf '%p\t%l\n' | LC_ALL=C sort
    ) > "$ARTIFACT_DIR/rootfs.symlinks"
}

function export_base_system() {
    rm -rf "$ARTIFACT_DIR"
    install -d -m 0755 "$ARTIFACT_DIR"

    chroot "$OUTPUTDIR" dpkg-query -W \
        --showformat='${binary:Package}\t${Version}\t${Architecture}\n' \
        | LC_ALL=C sort > "$ARTIFACT_DIR/packages.manifest"

    write_metadata_manifest

    tar \
        --sort=name \
        --format=pax \
        --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
        --numeric-owner \
        --xattrs \
        --acls \
        --selinux \
        --directory="$OUTPUTDIR" \
        --create \
        --file="$ARTIFACT_DIR/rootfs.tar" \
        .

    (
        cd "$ARTIFACT_DIR"
        sha256sum rootfs.tar > rootfs.tar.sha256
    )
}

verify_base_system
export_base_system
