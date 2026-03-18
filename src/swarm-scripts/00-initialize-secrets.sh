#!/bin/bash
set -euo pipefail

CONFIG="/sp/swarm/config.yaml"

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

ensure_secret "powerdns_api_url" "$POWERDNS_API_URL"
ensure_secret "powerdns_api_key" "$POWERDNS_API_KEY"
ensure_secret "base_domain" "$BASE_DOMAIN"
ensure_secret "swarm_domain" "$SWARM_DOMAIN"
ensure_secret "auth_service_yaml" "$AUTH_SERVICE_YAML"
ensure_secret "evidence_sign_key" "$EVIDENCE_SIGN_KEY"
