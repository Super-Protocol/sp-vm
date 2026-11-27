#!/bin/bash
# Select the TDX collateral source before quote generation or verification.
# online starts the in-guest PCCS. offline leaves it stopped and trusts the
# site CA written by the helper.

set -euo pipefail

helper="${SP_TDX_COLLATERAL_HELPER:-/usr/local/bin/pki-authority/pki_configure_helper.py}"
config="${SP_TDX_COLLATERAL_CONFIG:-/sp/swarm/config.yaml}"
qcnl="${SP_TDX_COLLATERAL_QCNL:-/etc/sgx_default_qcnl.conf}"
ca="${SP_TDX_COLLATERAL_CA:-/usr/local/share/ca-certificates/pccs-site.crt}"
mode_file="${SP_TDX_COLLATERAL_MODE:-/etc/swarm/tdx-collateral-mode}"

python3 "$helper" apply-tdx-collateral \
    --config "$config" \
    --qcnl "$qcnl" \
    --ca "$ca" \
    --mode-out "$mode_file"

if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates
fi

mode="$(tr -d '[:space:]' < "$mode_file")"
if [[ "$mode" == "online" ]]; then
    systemctl start pccs.service
    systemctl is-active --quiet pccs.service
fi
