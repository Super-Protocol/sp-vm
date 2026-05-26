#!/bin/bash
set -euo pipefail

CONFIG="/sp/swarm/config.yaml"
VM_MODE_FILE="/etc/swarm/swarm-vm-mode"

is_swarm_init_mode() {
  [ -f "$VM_MODE_FILE" ] || return 1
  [ "$(head -n1 "$VM_MODE_FILE" | tr -d '[:space:]')" = "init" ]
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
PKI_DOMAIN=$(cfg "pki_domain")
NODE_EXPORTER_ENABLED=$(cfg "node_exporter.enabled")

AUTH_SERVICE_YAML=""
AUTH_SERVICE_YAML_PATH="/sp/swarm/auth-service.yaml"
[ -f "$AUTH_SERVICE_YAML_PATH" ] && AUTH_SERVICE_YAML=$(cat "$AUTH_SERVICE_YAML_PATH")

NODE_EXPORTER_YAML=""
NODE_EXPORTER_YAML_PATH="/sp/swarm/node-exporter.yaml"

SWARM_INIT_CERTS_DIR=${SWARM_INIT_CERTS_DIR:-/etc/super/certs/swarm-init}
EVIDENCE_SIGN_KEY=""

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

  if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" get SwarmSecrets "$key" >/dev/null 2>&1; then
    echo "SwarmSecret '$key' already exists, skipping creation."
    return 0
  fi

  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create SwarmSecrets "$key" --value "$value" >/dev/null
}

is_enabled() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_node_exporter_secret() {
  if ! is_enabled "$NODE_EXPORTER_ENABLED"; then
    echo "INFO: skip node_exporter_yaml secret initialization, node_exporter.enabled is not true" >&2
    return 0
  fi

  [ -f "$NODE_EXPORTER_YAML_PATH" ] && NODE_EXPORTER_YAML=$(cat "$NODE_EXPORTER_YAML_PATH")
  ensure_secret "node_exporter_yaml" "$NODE_EXPORTER_YAML"
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

    [ "$secret_key" = "subroot_evidence_basic_key" ] && EVIDENCE_SIGN_KEY="$secret_value"
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
ensure_secret "pki_domain" "$PKI_DOMAIN"
ensure_secret "auth_service_yaml" "$AUTH_SERVICE_YAML"
load_node_exporter_secret
ensure_swarm_init_cert_secrets
ensure_secret "evidence_sign_key" "$EVIDENCE_SIGN_KEY"
