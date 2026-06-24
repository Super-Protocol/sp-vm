#!/bin/bash

set -euo pipefail

PCCS_ORIGINAL_LOCATION="/opt/intel"
PCCS_INSTALL_DIR="/usr/local"
PCCS_DIRNAME="sgx-dcap-pccs"

if [ ! -d "${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}" ]; then
    mkdir -p "${PCCS_ORIGINAL_LOCATION}"
    cp -rp "${PCCS_INSTALL_DIR}/${PCCS_DIRNAME}" "${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}"
fi
