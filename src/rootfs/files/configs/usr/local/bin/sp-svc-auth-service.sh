#!/bin/bash
set -euo pipefail

BASE_DIR="/etc/auth-service/"
APP_PATH="apps/auth-service"
APP_DIR="${BASE_DIR}/$APP_PATH"
SP_CONFIG="${APP_DIR}/configuration.yaml"

# Prefer configuration supplied via provider disk; fallback to example
if [[ -f "${SP_CONFIG}" ]]; then
  export CONFIG_FILE="${SP_CONFIG}"
elif [[ -f "${APP_DIR}/configuration.example.yaml" ]] && [[ "${ALLOW_EXAMPLE_CONFIG:-}" == "true" || "${NODE_ENV:-production}" != "production" ]]; then
  cp -f "${APP_DIR}/configuration.example.yaml" "${SP_CONFIG}"
  export CONFIG_FILE="${SP_CONFIG}"
else
  echo "ERROR: No configuration found for ${APP_PATH}. Expected one of: ${SP_CONFIG} or ${APP_DIR}/configuration.example.yaml" >&2
  exit 1
fi

export NODE_ENV="${NODE_ENV:-production}"
cd "${BASE_DIR}"
exec npm run start -w $APP_PATH
