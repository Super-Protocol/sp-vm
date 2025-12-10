#!/bin/bash
set -euo pipefail

BASE_DIR="/usr/local/lib/sp-swarm-services"
APP_PATH="apps/resource-certificates-service"
APP_DIR="${BASE_DIR}/$APP_PATH"
ETC_DIR="/etc/sp-swarm-services/$APP_PATH"
SP_CONFIG="/sp/swarm/services/sp-swarm-services/resource-certificates-service/configuration.yaml"
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
cd "${BASE_DIR}"
exec npm run start -w $APP_PATH
