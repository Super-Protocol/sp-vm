#!/bin/bash
set -euo pipefail

CONFIG="/sp/swarm/config.yaml"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [swarm-init] $*"; }

log "starting swarm initialization"

# Read a scalar value from /sp/swarm/config.yaml via python3+pyyaml
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
SERVICES_TAG=$(cfg "tags.services")
SWARM_CLOUD_API_TAG=$(cfg "tags.swarm_cloud_api")
SWARM_CLOUD_UI_TAG=$(cfg "tags.swarm_cloud_ui")
AUTH_SERVICE_TAG=$(cfg "tags.auth_service")
POWERDNS_API_URL=$(cfg "powerdns_api_url")
POWERDNS_API_KEY=$(cfg "powerdns_api_key")
BASE_DOMAIN=$(cfg "base_domain")

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

# Install swarm-db binary from GitHub Releases (idempotent: skip if already installed)
if [ -n "$SWARM_DB_TAG" ]; then
    if [ -f "/usr/local/bin/swarm-db-linux-amd64" ]; then
        log "swarm-db already installed, skipping"
    else
        log "installing swarm-db $SWARM_DB_TAG..."
        FILENAME="swarm-db-${SWARM_DB_TAG}-linux-amd64.tar.gz"
        TMP=$(mktemp -d)
        download_github_asset "Super-Protocol" "swarm-db" "$SWARM_DB_TAG" "$FILENAME" "$TMP/swarm-db.tar.gz"
        tar xzf "$TMP/swarm-db.tar.gz" -C "$TMP"
        install -m 755 "$TMP/swarm-db" /usr/local/bin/swarm-db-linux-amd64
        rm -rf "$TMP"
        log "swarm-db $SWARM_DB_TAG installed"
    fi
else
    log "tags.swarm_db not set, using built-in swarm-db binary"
fi

# Install provision-plugin-sdk from GitHub Releases (pip install is idempotent)
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

# Download swarm-services from GitHub Release into /etc/swarm-services (always overwrite)
if [ -n "$SERVICES_TAG" ]; then
    log "downloading swarm-services $SERVICES_TAG..."
    TMP=$(mktemp -d)
    REL_FILE=$(mktemp)
    auth_curl_args=()
    [ -n "$GITHUB_TOKEN" ] && auth_curl_args=(-H "Authorization: token $GITHUB_TOKEN")

    if ! curl -sf "${auth_curl_args[@]}" \
            "https://api.github.com/repos/Super-Protocol/swarm-cloud/releases/tags/$SERVICES_TAG" \
            -o "$REL_FILE"; then
        rm -f "$REL_FILE"
        log "ERROR: failed to fetch release info for swarm-services $SERVICES_TAG"
        exit 1
    fi

    GITHUB_TOKEN="$GITHUB_TOKEN" REL_FILE="$REL_FILE" TMP_DIR="$TMP" \
    python3 - << 'PYEOF'
import json, os, subprocess, re, zipfile

github_token = os.environ.get('GITHUB_TOKEN', '')
rel_file = os.environ['REL_FILE']
tmp_dir = os.environ['TMP_DIR']
services_dir = '/etc/swarm-services'

with open(rel_file) as f:
    data = json.load(f)
os.unlink(rel_file)

os.makedirs(services_dir, exist_ok=True)
auth_headers = ['-H', f'Authorization: token {github_token}'] if github_token else []

for asset in data.get('assets', []):
    name = asset['name']
    if not name.endswith('.zip'):
        continue
    asset_id = asset['id']
    service_name = re.sub(r'^(.+?)-v[\d][^/]*\.zip$', r'\1', name)
    dest = os.path.join(tmp_dir, name)

    subprocess.run(
        ['curl', '-sfL'] + auth_headers + [
            '-H', 'Accept: application/octet-stream',
            '-o', dest,
            f'https://api.github.com/repos/Super-Protocol/swarm-cloud/releases/assets/{asset_id}',
        ],
        check=True,
    )

    svc_dir = os.path.join(services_dir, service_name)
    os.makedirs(svc_dir, exist_ok=True)
    with zipfile.ZipFile(dest, 'r') as zf:
        zf.extractall(svc_dir)

    if not os.path.exists(os.path.join(svc_dir, 'manifest.yaml')):
        print(f'ERROR: manifest.yaml not found in {service_name}', flush=True)
        raise SystemExit(1)

    main_py = os.path.join(svc_dir, 'main.py')
    if os.path.exists(main_py):
        os.chmod(main_py, 0o755)

    print(f'installed service: {service_name}', flush=True)
PYEOF
    rm -rf "$TMP"
    log "swarm-services $SERVICES_TAG installed"
else
    log "tags.services not set, skipping swarm-services download"
fi

# Install swarm-host-agent from GitHub Releases (idempotent: skip if already installed)
# Tag format: "host-agent-vX.Y.Z" → release tag "release-vX.Y.Z"
if [ -n "$HOST_AGENT_TAG" ]; then
    if [ -f "/usr/local/bin/swarm-host-agent" ]; then
        log "swarm-host-agent already installed, skipping"
    else
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
        EXTRACT_DIR=$(ls -1 "$TMP" | grep -v 'host-agent\.tar\.gz' | head -1)
        install -m 755 "$TMP/$EXTRACT_DIR/swarm-host-agent" /usr/local/bin/swarm-host-agent
        mkdir -p /etc/swarm
        cp "$TMP/$EXTRACT_DIR/host-agent.yaml" /etc/swarm/host-agent.yaml
        rm -rf "$TMP"
        log "swarm-host-agent $RELEASE_TAG installed"
        systemctl daemon-reload
        systemctl enable swarm-host-agent.service
    fi
else
    log "ERROR: tags.host_agent is required"
    exit 1
fi

# Authenticate to ghcr.io for pulling swarm-node container image (idempotent)
if [ -n "$GITHUB_TOKEN" ]; then
    log "authenticating to ghcr.io..."
    echo "$GITHUB_TOKEN" | podman login ghcr.io -u oauth2 --password-stdin
    log "ghcr.io login successful"
else
    log "WARNING: github.token not set, skipping ghcr.io login (image must be publicly accessible)"
fi

# Generate /etc/swarm/swarm-node.env for swarm-node.service EnvironmentFile (idempotent)
log "generating /etc/swarm/swarm-node.env..."
mkdir -p /etc/swarm
cat > /etc/swarm/swarm-node.env << EOF
SWARM_NODE_TAG=${SWARM_NODE_TAG}
EOF

# Generate /etc/swarm/swarm-host-agent.env for swarm-host-agent.service EnvironmentFile (idempotent)
log "generating /etc/swarm/swarm-host-agent.env..."
cat > /etc/swarm/swarm-host-agent.env << EOF
SWARM_CLOUD_API_TAG=${SWARM_CLOUD_API_TAG}
SWARM_CLOUD_UI_TAG=${SWARM_CLOUD_UI_TAG}
AUTH_SERVICE_TAG=${AUTH_SERVICE_TAG}
EOF

# Wait for swarm-db MySQL — fail (and let systemd restart us) if not available
log "waiting for swarm-db MySQL to become available..."
mysql_host="127.0.0.1"
mysql_port="3306"
wait_timeout="120"
start_ts="$(date +%s)"
while true; do
    if (exec 3<>/dev/tcp/"$mysql_host"/"$mysql_port") 2>/dev/null; then
        exec 3>&- 3<&-
        break
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    if [ "$elapsed" -ge "$wait_timeout" ]; then
        log "ERROR: MySQL not available after ${wait_timeout}s, will retry"
        exit 1
    fi
    sleep 1
done

# Insert SwarmSecrets (idempotent: INSERT IGNORE skips existing keys)
log "inserting SwarmSecrets into swarm-db..."
AUTH_SERVICE_YAML=""
AUTH_SERVICE_YAML_PATH="/sp/swarm/auth-service.yaml"
[ -f "$AUTH_SERVICE_YAML_PATH" ] && AUTH_SERVICE_YAML=$(cat "$AUTH_SERVICE_YAML_PATH")

# Generate RSA 4096 private key (PKCS8 PEM) for evidence signing.
# INSERT IGNORE ensures only the first run inserts it; subsequent runs are no-ops.
# TODO: should we use subroot (intermediate CA) key hierarchy?
log "generating evidence signing key (RSA 4096)..."
EVIDENCE_SIGN_KEY=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 2>/dev/null)

POWERDNS_API_URL="$POWERDNS_API_URL" \
POWERDNS_API_KEY="$POWERDNS_API_KEY" \
BASE_DOMAIN="$BASE_DOMAIN" \
AUTH_SERVICE_YAML="$AUTH_SERVICE_YAML" \
EVIDENCE_SIGN_KEY="$EVIDENCE_SIGN_KEY" \
python3 - << 'PYEOF'
import subprocess, os

def insert_secret(key, value):
    if not value:
        return
    escaped = value.replace("'", "''")
    sql = f"INSERT IGNORE INTO SwarmSecrets (id, value) VALUES ('{key}', '{escaped}');\n"
    subprocess.run(
        ["mysql", "-h", "127.0.0.1", "-P", "3306", "-u", "root", "swarmdb"],
        input=sql, text=True, check=True,
    )

insert_secret("powerdns_api_url",  os.environ.get("POWERDNS_API_URL", ""))
insert_secret("powerdns_api_key",  os.environ.get("POWERDNS_API_KEY", ""))
insert_secret("base_domain",       os.environ.get("BASE_DOMAIN", ""))
insert_secret("auth_service_yaml", os.environ.get("AUTH_SERVICE_YAML", ""))
insert_secret("evidence_sign_key", os.environ.get("EVIDENCE_SIGN_KEY", ""))
PYEOF

log "swarm-init completed successfully"
