#!/bin/bash
set -e

CONTAINER_NAME="pki-authority"

if lxc-info -n "$CONTAINER_NAME" &>/dev/null; then
  echo "Container '$CONTAINER_NAME' already exists."
else
  echo "Container '$CONTAINER_NAME' not found. Creating..."
  lxc-create -n "$CONTAINER_NAME" -t oci -- --url docker-archive://root/containers/pki-authority.tar
  echo "Container '$CONTAINER_NAME' created."
fi

CPU_TYPE="untrusted"
if [[ -c "/dev/tdx_guest" ]] ; then
    CPU_TYPE="tdx";
elif [[ -c "/dev/sev-guest" ]]; then
    CPU_TYPE="sev-snp";
fi

export CPU_TYPE="$CPU_TYPE"

SRC_YAML="/root/containers/lxc-template.yaml"
DST_YAML="/var/lib/lxc/pki-authority/rootfs/app/conf/lxc.yaml"

if [ -f "$SRC_YAML" ]; then
    if command -v yq-go >/dev/null 2>&1; then
        yq-go e '.pki.ownChallenge.type = strenv(CPU_TYPE)' "$SRC_YAML" > "$DST_YAML"
        echo "Patched $DST_YAML with type: $CPU_TYPE using yq."
    else
        echo "Error: yq-go is not installed. Please install yq-go for YAML editing."
        exit 1
    fi
else
    echo "Error: $SRC_YAML not found."
    exit 1
fi

CONFIG_FILE="/var/lib/lxc/pki-authority/config"
CONFIG_BAK="${CONFIG_FILE}.bak"

# Always restore config from backup if backup exists
if [ -f "$CONFIG_BAK" ]; then
    cp "$CONFIG_BAK" "$CONFIG_FILE"
else
    # Create backup before first patch
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$CONFIG_BAK"
    fi
fi

# hardware address for the container
echo "lxc.net.0.hwaddr = 4e:fc:0a:d5:2d:ff" >> "$CONFIG_FILE"

if [ "$CPU_TYPE" = "sev-snp" ]; then
    DEV_ID=$(stat -c '%t:%T' /dev/sev-guest | awk -F: '{printf "%d:%d\n", "0x"$1, "0x"$2}')
    echo "lxc.cgroup2.devices.allow = c $DEV_ID rwm" >> "$CONFIG_FILE"
    echo "lxc.mount.entry = /dev/sev-guest dev/sev-guest none bind,optional,create=file" >> "$CONFIG_FILE"
elif [ "$CPU_TYPE" = "tdx" ]; then
    DEV_ID=$(stat -c '%t:%T' /dev/tdx_guest | awk -F: '{printf "%d:%d\n", "0x"$1, "0x"$2}')
    echo "lxc.cgroup2.devices.allow = c $DEV_ID rwm" >> "$CONFIG_FILE"
    echo "lxc.mount.entry = /dev/tdx_guest dev/tdx_guest none bind,optional,create=file" >> "$CONFIG_FILE"
    if [ -f "/etc/tdx-attest.conf" ]; then
        echo "lxc.mount.entry = /etc/tdx-attest.conf etc/tdx-attest.conf none bind,ro,create=file" >> "$CONFIG_FILE"
    fi
fi
