#!/bin/bash
set -euo pipefail

CONFIG="/etc/swarm/config.yaml"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [swarm-init] $*"; }

log "starting swarm initialization"

# Read a scalar value from /etc/swarm/config.yaml via python3+pyyaml
cfg() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG')) or {}
v = c
for k in '$1'.split('.'):
    v = v.get(k) if isinstance(v, dict) else None
print('' if v is None else v)"
}

GITHUB_TOKEN=$(cfg "github.token")
SWARM_DB_TAG=$(cfg "tags.swarm_db")
HOST_AGENT_TAG=$(cfg "tags.host_agent")
SWARM_NODE_TAG=$(cfg "tags.swarm_node")
SDK_TAG=$(cfg "tags.sdk")
SWARM_CLOUD_API_TAG=$(cfg "tags.swarm_cloud_api")
SWARM_CLOUD_UI_TAG=$(cfg "tags.swarm_cloud_ui")
AUTH_SERVICE_TAG=$(cfg "tags.auth_service")
NODE_NAME=$(cfg "swarm_db.node_name")
ADVERTISE_ADDR=$(cfg "swarm_db.advertise_addr")

# Resolve node name
[ -z "$NODE_NAME" ] && NODE_NAME=$(hostname)

# Auto-detect external IP if not configured
if [ -z "$ADVERTISE_ADDR" ]; then
    log "auto-detecting external IP..."
    ADVERTISE_ADDR=$(curl -sf --max-time 5 https://myip.wtf/json \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('YourFuckingIPAddress',''))" 2>/dev/null || true)
    [ -z "$ADVERTISE_ADDR" ] && \
        ADVERTISE_ADDR=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$ADVERTISE_ADDR" ]; then
        log "WARNING: could not detect external IP, using 127.0.0.1"
        ADVERTISE_ADDR="127.0.0.1"
    fi
    log "detected advertise_addr: $ADVERTISE_ADDR"
fi

# Download a GitHub release asset to a local file path
# Usage: download_github_asset <owner> <repo> <tag> <filename> <dest>
download_github_asset() {
    local owner="$1" repo="$2" tag="$3" filename="$4" dest="$5"
    local auth_args=()
    [ -n "$GITHUB_TOKEN" ] && auth_args=(-H "Authorization: token $GITHUB_TOKEN")

    local rel_file; rel_file=$(mktemp)
    if ! curl -sf "${auth_args[@]}" \
            "https://api.github.com/repos/$owner/$repo/releases/tags/$tag" \
            -o "$rel_file"; then
        rm -f "$rel_file"
        log "ERROR: failed to fetch release info for $owner/$repo@$tag"
        return 1
    fi

    local asset_id
    asset_id=$(python3 -c "
import json
with open('$rel_file') as f:
    data = json.load(f)
for a in data.get('assets', []):
    if a['name'] == '$filename':
        print(a['id']); break
" 2>/dev/null || true)
    rm -f "$rel_file"

    if [ -z "$asset_id" ]; then
        log "ERROR: asset '$filename' not found in $owner/$repo@$tag"
        return 1
    fi

    curl -sfL "${auth_args[@]}" \
        -H "Accept: application/octet-stream" \
        -o "$dest" \
        "https://api.github.com/repos/$owner/$repo/releases/assets/$asset_id"
}

# Install swarm-db binary from GitHub Releases
if [ -n "$SWARM_DB_TAG" ]; then
    log "installing swarm-db $SWARM_DB_TAG..."
    FILENAME="swarm-db-${SWARM_DB_TAG}-linux-amd64.tar.gz"
    TMP=$(mktemp -d)
    download_github_asset "Super-Protocol" "swarm-db" "$SWARM_DB_TAG" "$FILENAME" "$TMP/swarm-db.tar.gz"
    tar xzf "$TMP/swarm-db.tar.gz" -C "$TMP"
    install -m 755 "$TMP/swarm-db" /usr/local/bin/swarm-db-linux-amd64
    rm -rf "$TMP"
    log "swarm-db $SWARM_DB_TAG installed"
else
    log "tags.swarm_db not set, using built-in swarm-db binary"
fi

# Install provision-plugin-sdk from GitHub Releases
if [ -n "$SDK_TAG" ]; then
    log "installing provision-plugin-sdk $SDK_TAG..."
    FILENAME="provision-plugin-sdk-${SDK_TAG}.tar.gz"
    TMP=$(mktemp -d)
    download_github_asset "Super-Protocol" "swarm-cloud" "$SDK_TAG" "$FILENAME" "$TMP/sdk.tar.gz"
    tar xzf "$TMP/sdk.tar.gz" -C "$TMP"
    pip3 install --break-system-packages --quiet "$TMP"
    rm -rf "$TMP"
    log "provision-plugin-sdk $SDK_TAG installed"
else
    log "tags.sdk not set, using built-in provision-plugin-sdk"
fi

# Install swarm-host-agent from GitHub Releases
# Tag format: "host-agent-vX.Y.Z" → release tag "release-vX.Y.Z"
if [ -n "$HOST_AGENT_TAG" ]; then
    log "installing swarm-host-agent $HOST_AGENT_TAG..."
    if [[ "$HOST_AGENT_TAG" == release-* ]]; then
        RELEASE_TAG="$HOST_AGENT_TAG"
    elif [[ "$HOST_AGENT_TAG" == host-agent-* ]]; then
        VERSION="${HOST_AGENT_TAG#host-agent-}"
        RELEASE_TAG="release-$VERSION"
    else
        RELEASE_TAG="release-$HOST_AGENT_TAG"
    fi
    FILENAME="swarm-host-agent-${RELEASE_TAG}-linux-amd64.tar.gz"
    TMP=$(mktemp -d)
    download_github_asset "Super-Protocol" "swarm-cloud" "$RELEASE_TAG" "$FILENAME" "$TMP/host-agent.tar.gz"
    tar xzf "$TMP/host-agent.tar.gz" -C "$TMP"
    EXTRACT_DIR=$(tar -tzf "$TMP/host-agent.tar.gz" | head -1 | cut -f1 -d"/")
    install -m 755 "$TMP/$EXTRACT_DIR/swarm-host-agent" /usr/local/bin/swarm-host-agent
    mkdir -p /etc/swarm
    cp "$TMP/$EXTRACT_DIR/host-agent.yaml" /etc/swarm/host-agent.yaml
    cp "$TMP/$EXTRACT_DIR/swarm-host-agent.service" /etc/systemd/system/swarm-host-agent.service
    rm -rf "$TMP"
    log "swarm-host-agent $RELEASE_TAG installed"
    systemctl daemon-reload
    systemctl enable swarm-host-agent.service
else
    log "ERROR: tags.host_agent is required"
    exit 1
fi

# Authenticate to ghcr.io for pulling swarm-node container image
if [ -n "$GITHUB_TOKEN" ]; then
    log "authenticating to ghcr.io..."
    echo "$GITHUB_TOKEN" | podman login ghcr.io -u oauth2 --password-stdin
    log "ghcr.io login successful"
else
    log "WARNING: github.token not set, skipping ghcr.io login (image must be publicly accessible)"
fi

# Generate /etc/swarm/swarm-node.env for swarm-node.service EnvironmentFile
log "generating /etc/swarm/swarm-node.env..."
mkdir -p /etc/swarm
cat > /etc/swarm/swarm-node.env << EOF
SWARM_NODE_TAG=${SWARM_NODE_TAG}
SWARM_CLOUD_API_TAG=${SWARM_CLOUD_API_TAG}
SWARM_CLOUD_UI_TAG=${SWARM_CLOUD_UI_TAG}
AUTH_SERVICE_TAG=${AUTH_SERVICE_TAG}
EOF

# Generate /etc/swarm-db/config.yaml from /etc/swarm/config.yaml parameters
log "generating /etc/swarm-db/config.yaml (node=$NODE_NAME, advertise=$ADVERTISE_ADDR)..."
mkdir -p /etc/swarm-db /var/lib/swarm-db

NODE_NAME_VAL="$NODE_NAME" ADVERTISE_ADDR_VAL="$ADVERTISE_ADDR" \
python3 - << 'PYEOF'
import yaml, os

with open('/etc/swarm/config.yaml') as f:
    swarm_cfg = yaml.safe_load(f) or {}

join_addresses = (swarm_cfg.get('swarm_db') or {}).get('join_addresses') or []

config = {
    'node': {
        'name': os.environ['NODE_NAME_VAL'],
        'host': '0.0.0.0',
        'port': 8001,
        'data_dir': '/var/lib/swarm-db',
        'schema_file': '/etc/swarm-db/schema.yaml',
    },
    'memberlist': {
        'bind_addr': '0.0.0.0',
        'bind_port': 7946,
        'advertise_addr': os.environ['ADVERTISE_ADDR_VAL'],
        'advertise_port': 7946,
        'join_addresses': join_addresses,
        'gossip_interval': '200ms',
        'probe_interval': '1s',
        'probe_timeout': '500ms',
        'suspicion_max_time_multiplier': 6,
    },
    'sql': {
        'enabled': True,
        'host': '0.0.0.0',
        'port': 3306,
        'system_database': 'swarmdb',
    },
    'jq': {
        'enabled': True,
        'host': '0.0.0.0',
        'port': 8080,
    },
}

with open('/etc/swarm-db/config.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
PYEOF

log "swarm-init completed successfully"
