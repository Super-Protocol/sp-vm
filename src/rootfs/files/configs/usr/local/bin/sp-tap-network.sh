#!/bin/bash
# sp-tap-network.sh — configure the VM's network from MAC-bound kernel params.
#
# Reads spnet.* parameters injected by start_super_protocol.sh (tap mode):
#   spnet.mac=<lower-case MAC>     which NIC to configure (authoritative)
#   spnet.ip=<addr>/<prefix>       static address in CIDR form
#   spnet.gw=<gateway>             default gateway (optional)
#
# Why match by MAC and not by interface name:
#   The PCI slot a virtio-net device lands on depends on the full device set
#   (GPU passthrough, vsock, extra debug NIC, machine type), so the kernel name
#   (enp0s1 / enp0s2 / ens1 / …) is NOT stable across our three node types.
#   The MAC, however, is set explicitly on the QEMU command line and is stable.
#   We resolve MAC -> current ifname here, then pin a systemd-networkd .network
#   file that itself matches by MAC, so networkd owns the link legitimately and
#   will not reset the address.
set -euo pipefail

log() { echo "sp-tap-network: $*" >&2; }

# --- read /proc/cmdline ----------------------------------------------------
read_param() {
    # extract value of key=... from /proc/cmdline; empty if absent
    local key="$1"
    tr ' ' '\n' < /proc/cmdline | grep "^${key}=" | head -1 | cut -d= -f2- || true
}

MAC="$(read_param spnet.mac)"
IPCIDR="$(read_param spnet.ip)"
GW="$(read_param spnet.gw)"

# Nothing to do if the network params were not provided (e.g. user-mode netdev).
if [[ -z "${MAC}" || -z "${IPCIDR}" ]]; then
    log "spnet.mac/spnet.ip not present on cmdline — nothing to configure, exiting 0"
    exit 0
fi

MAC="${MAC,,}"   # normalise to lower-case

# --- validate the CIDR ------------------------------------------------------
if [[ ! "${IPCIDR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    log "ERROR: spnet.ip='${IPCIDR}' is not a valid CIDR (expected a.b.c.d/prefix)"
    exit 1
fi

# --- resolve MAC -> current interface name (best-effort, for logging) -------
# We do NOT rely on this name for the actual config (networkd matches by MAC),
# but it is useful for logs and for an immediate `ip` fallback if needed.
DEV=""
for iface_path in /sys/class/net/*; do
    iface="$(basename "${iface_path}")"
    [[ "${iface}" == "lo" ]] && continue
    if [[ -r "${iface_path}/address" ]]; then
        cur="$(cat "${iface_path}/address" 2>/dev/null || true)"
        if [[ "${cur,,}" == "${MAC}" ]]; then
            DEV="${iface}"
            break
        fi
    fi
done

if [[ -n "${DEV}" ]]; then
    log "MAC ${MAC} currently maps to interface ${DEV}"
else
    # Not fatal: the NIC may enumerate slightly later. networkd will still apply
    # the .network file by MAC once the link appears.
    log "WARN: no interface currently has MAC ${MAC}; writing config anyway (networkd will match on appearance)"
fi

# --- write a systemd-networkd .network file matched BY MAC ------------------
mkdir -p /etc/systemd/network
NET_FILE="/etc/systemd/network/10-spnet.network"

{
    echo "[Match]"
    echo "MACAddress=${MAC}"
    echo ""
    echo "[Link]"
    echo "RequiredForOnline=yes"
    echo ""
    echo "[Network]"
    echo "Address=${IPCIDR}"
    [[ -n "${GW}" ]] && echo "Gateway=${GW}"
} > "${NET_FILE}"

log "wrote ${NET_FILE}:"
sed 's/^/  /' "${NET_FILE}" >&2

# Make sure networkd is the thing managing links.
systemctl enable systemd-networkd >/dev/null 2>&1 || true

log "done"
exit 0
