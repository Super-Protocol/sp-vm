#!/bin/bash
set -euo pipefail

APP_DIR="/usr/local/lib/sp-swarm-services/apps/workload-service"
ETC_DIR="/etc/sp-swarm-services/apps/workload-service"
SP_CONFIG="/sp/swarm/services/sp-swarm-services/workload-service/configuration.yaml"
ETC_CONFIG="${ETC_DIR}/configuration.yaml"

mkdir -p "${ETC_DIR}"

if [[ -f "${SP_CONFIG}" ]]; then
  export CONFIG_FILE="${SP_CONFIG}"
elif [[ -f "${ETC_CONFIG}" ]]; then
  export CONFIG_FILE="${ETC_CONFIG}"
else
  if [[ -f "${APP_DIR}/configuration.example.yaml" ]]; then
    cp -f "${APP_DIR}/configuration.example.yaml" "${ETC_CONFIG}"
    export CONFIG_FILE="${ETC_CONFIG}"
  fi
fi

export NODE_ENV="${NODE_ENV:-production}"
cd "${APP_DIR}"
exec node ./dist/main.js
