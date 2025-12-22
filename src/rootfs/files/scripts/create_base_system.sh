#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# VERSION_CODENAME
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
TARGET_ARCH="amd64";

BASE_PACKAGES="init,openssh-server,netplan.io,curl,htop,open-iscsi,cryptsetup,ca-certificates,gnupg2,kmod,gcc-13,build-essential,chrony,iptables,dbus,cryptsetup-bin,e2fsprogs,gettext,lxc,lxc-templates,wireguard"

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function create_base_system() {
    log_info "creating base system";
    debootstrap \
        "--arch=$TARGET_ARCH" \
        --variant=minbase \
        "--include=$BASE_PACKAGES" \
        --components=main,universe \
        "$VERSION_CODENAME" \
        "$OUTPUTDIR" \
        http://us.archive.ubuntu.com/ubuntu/ \
        || log_fail "failed to create base system";
}

create_base_system;