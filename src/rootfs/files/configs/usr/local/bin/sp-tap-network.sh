#!/bin/bash
# Convert kernel ip= parameter to systemd-networkd .network file
set -euo pipefail

IP_PARAM=$(cat /proc/cmdline | tr ' ' '\n' | grep '^ip=' | head -1 | cut -d= -f2- || true)
[[ -z "${IP_PARAM}" ]] && exit 0

# Parse: ip=<client>:<server>:<gw>:<netmask>:<hostname>:<device>:<autoconf>
IFS=':' read -r IP SRV GW MASK HOST DEV AUTOCONF <<< "${IP_PARAM}"
[[ -z "${DEV}" ]] && DEV="enp0s1"

# Convert netmask to CIDR prefix
PREFIX=24
case "${MASK}" in
    255.0.0.0)       PREFIX=8  ;;
    255.255.0.0)     PREFIX=16 ;;
    255.255.255.0)   PREFIX=24 ;;
esac

mkdir -p /etc/systemd/network
cat > "/etc/systemd/network/10-${DEV}.network" << NETEOF
[Match]
Name=${DEV}

[Network]
Address=${IP}/${PREFIX}
NETEOF
[[ -n "${GW}" ]] && echo "Gateway=${GW}" >> "/etc/systemd/network/10-${DEV}.network"
