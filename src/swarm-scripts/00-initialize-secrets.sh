#!/bin/bash
set -euo pipefail

CONFIG="/sp/swarm/config.yaml"

is_swarm_init_mode() {
  grep -q 'vm_mode=swarm-init' /proc/cmdline
}

cfg() {
  python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG')) or {}
v = c
for k in '$1'.split('.'):
    v = v.get(k) if isinstance(v, dict) else None
print('' if v is None else v)"
}

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

POWERDNS_API_URL=$(cfg "powerdns_api_url")
POWERDNS_API_KEY=$(cfg "powerdns_api_key")
BASE_DOMAIN=$(cfg "base_domain")
SWARM_DOMAIN=$(cfg "swarm_domain")

AUTH_SERVICE_YAML=""
AUTH_SERVICE_YAML_PATH="/sp/swarm/auth-service.yaml"
[ -f "$AUTH_SERVICE_YAML_PATH" ] && AUTH_SERVICE_YAML=$(cat "$AUTH_SERVICE_YAML_PATH")

EVIDENCE_SIGN_KEY=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 2>/dev/null)
SWARM_INIT_CERTS_DIR=${SWARM_INIT_CERTS_DIR:-/etc/super/certs/swarm-init}

SWARM_INIT_CERT_SECRET_KEYS=(
  "root_basic_cert"
  "root_basic_key"
  "root_lite_cert"
  "root_lite_key"
  "subroot_device_basic_cert"
  "subroot_device_basic_key"
  "subroot_device_lite_cert"
  "subroot_device_lite_key"
  "subroot_evidence_basic_cert"
  "subroot_evidence_basic_key"
  "subroot_evidence_lite_cert"
  "subroot_evidence_lite_key"
)

ensure_secret() {
  local key="$1"
  local value="$2"
  [ -n "$value" ] || return 0

  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create SwarmSecrets "$key" --value "$value" >/dev/null
}

ensure_swarm_init_cert_secrets() {
  local secret_key
  local prefixed_secret_key
  local cert_file
  local cert_path
  local secret_value
  local pki_auth_token

  if ! is_swarm_init_mode; then
    echo "INFO: skip pki cert secrets initialization, vm_mode is not swarm-init" >&2
    return 0
  fi

  pki_auth_token="$(openssl rand -base64 64)"
  ensure_secret "pki_auth_token" "$pki_auth_token"

  for secret_key in "${SWARM_INIT_CERT_SECRET_KEYS[@]}"; do
    cert_file="${secret_key}.pem"
    cert_path="${SWARM_INIT_CERTS_DIR}/${cert_file}"

    if [ ! -f "$cert_path" ]; then
      echo "ERROR: required cert file is missing: $cert_path" >&2
      return 1
    fi

    prefixed_secret_key="pki_${secret_key}"
    secret_value="$(cat "$cert_path")"
    ensure_secret "$prefixed_secret_key" "$secret_value"
  done

  if [ -z "$SWARM_INIT_CERTS_DIR" ] || [ "$SWARM_INIT_CERTS_DIR" = "/" ]; then
    echo "ERROR: unsafe SWARM_INIT_CERTS_DIR value: '$SWARM_INIT_CERTS_DIR'" >&2
    return 1
  fi

  if [ ! -d "$SWARM_INIT_CERTS_DIR" ]; then
    echo "ERROR: SWARM_INIT_CERTS_DIR is not a directory: $SWARM_INIT_CERTS_DIR" >&2
    return 1
  fi

  rm -rf "$SWARM_INIT_CERTS_DIR"
}

ensure_secret "powerdns_api_url" "$POWERDNS_API_URL"
ensure_secret "powerdns_api_key" "$POWERDNS_API_KEY"
ensure_secret "base_domain" "$BASE_DOMAIN"
ensure_secret "swarm_domain" "$SWARM_DOMAIN"
ensure_secret "auth_service_yaml" "$AUTH_SERVICE_YAML"
ensure_secret "evidence_sign_key" "$EVIDENCE_SIGN_KEY"
ensure_swarm_init_cert_secrets
