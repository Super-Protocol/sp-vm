#!/bin/bash
set -euo pipefail

APP_DIR="/usr/local/lib/sp-swarm-services/apps/api-gateway"
ETC_DIR="/etc/sp-swarm-services/apps/api-gateway"
SP_CONFIG="/sp/swarm/services/sp-swarm-services/api-gateway/configuration.yaml"
ETC_CONFIG="${ETC_DIR}/configuration.yaml"

mkdir -p "${ETC_DIR}"

# Prefer configuration supplied via provider disk (read-only)
if [[ -f "${SP_CONFIG}" ]]; then
  export CONFIG_FILE="${SP_CONFIG}"
elif [[ -f "${ETC_CONFIG}" ]]; then
  export CONFIG_FILE="${ETC_CONFIG}"
else
  # fall back to copying example if present
  if [[ -f "${APP_DIR}/configuration.example.yaml" ]]; then
    cp -f "${APP_DIR}/configuration.example.yaml" "${ETC_CONFIG}"
    export CONFIG_FILE="${ETC_CONFIG}"
  fi
fi

export NODE_ENV="${NODE_ENV:-production}"
cd "${APP_DIR}"
exec node ./dist/main.js
