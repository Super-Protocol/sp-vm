#!/bin/bash
# sp-tap-network.sh — configure the VM's network from provider_config.
#
# Reads spnet.* values from provider_config swarm/config.yaml:
#   spnet.mac     which NIC to configure (authoritative)
#   spnet.ip      static address in CIDR form
#   spnet.gw      default gateway (optional)
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

# --- read provider_config --------------------------------------------------
CONFIG_CANDIDATES=(
    "${SPNET_CONFIG:-}"
    "/provider_config/swarm/config.yaml"
    "/sp/swarm/config.yaml"
)

read_spnet_config() {
    local config="$1"
    local output
    local values=()

    if ! output="$(python3 - "${config}" <<'PY'
import sys
import yaml

config_path = sys.argv[1]

with open(config_path, "r", encoding="utf-8") as f:
    config = yaml.safe_load(f) or {}

spnet = config.get("spnet") if isinstance(config, dict) else None
if not isinstance(spnet, dict):
    spnet = {}

for key in ("mac", "ip", "gw"):
    value = spnet.get(key)
    print("" if value is None else str(value))

print("__SPNET_END__")
PY
)"; then
        log "ERROR: failed to read spnet config from ${config}"
        return 1
    fi

    mapfile -t values <<< "${output}"
    MAC="${values[0]:-}"
    IPCIDR="${values[1]:-}"
    GW="${values[2]:-}"
}

CONFIG=""
for candidate in "${CONFIG_CANDIDATES[@]}"; do
    [[ -z "${candidate}" ]] && continue
    if [[ -s "${candidate}" ]]; then
        CONFIG="${candidate}"
        break
    fi
done

if [[ -z "${CONFIG}" ]]; then
    log "provider_config swarm/config.yaml not found — nothing to configure, exiting 0"
    exit 0
fi

read_spnet_config "${CONFIG}"
log "read spnet config from ${CONFIG}"

# Nothing to do if tap network params were not provided (e.g. user-mode netdev).
if [[ -z "${MAC}" || -z "${IPCIDR}" ]]; then
    log "spnet.mac/spnet.ip not present in ${CONFIG} — nothing to configure, exiting 0"
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
NET_FILE="/etc/systemd/network/05-spnet.network"

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
