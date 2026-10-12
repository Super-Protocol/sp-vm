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
PKI_AUTHORITY_TAG=$(cfg "tags.pki_authority")
GATEKEEPER_S3_IMAGE=$(cfg "tags.gatekeeper_s3_image")
GATEKEEPER_HARBOR_IMAGE=$(cfg "tags.gatekeeper_harbor_image")

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
        if [ "${DOWNLOAD_GITHUB_ASSET_QUIET:-0}" != "1" ]; then
            log "ERROR: failed to fetch release info for $owner/$repo@$tag"
        fi
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
    SDK_RELEASE_TAG="sdk-${SDK_TAG}"
    FILENAME="provision-plugin-sdk-${SDK_TAG}.tar.gz"
    TMP=$(mktemp -d)
    download_github_asset "Super-Protocol" "swarm-cloud" "$SDK_RELEASE_TAG" "$FILENAME" "$TMP/sdk.tar.gz"
    tar xzf "$TMP/sdk.tar.gz" -C "$TMP"
    pip3 install --break-system-packages --quiet "$TMP"
    rm -rf "$TMP"
    log "provision-plugin-sdk $SDK_TAG installed"
else
    log "tags.sdk not set, using built-in provision-plugin-sdk"
fi

# Download swarm-services from GitHub Pages into /etc/swarm-services (always overwrite)
# URL: https://super-protocol.github.io/swarm-cloud-services/<tags.services>/
if [ -n "$SERVICES_TAG" ]; then
    log "downloading swarm-services $SERVICES_TAG..."
    TMP=$(mktemp -d)
    INDEX_URL="https://super-protocol.github.io/swarm-cloud-services/${SERVICES_TAG}/index.json?v=$(date +%s)"
    INDEX_FILE="$TMP/index.json"

    if ! curl -sfL "$INDEX_URL" -o "$INDEX_FILE"; then
        rm -rf "$TMP"
        log "ERROR: failed to fetch services index from $INDEX_URL"
        exit 1
    fi

    SERVICES_TAG="$SERVICES_TAG" INDEX_FILE="$INDEX_FILE" TMP_DIR="$TMP" \
    python3 - << 'PYEOF'
import hashlib, json, os, subprocess, zipfile

services_tag = os.environ['SERVICES_TAG']
index_file = os.environ['INDEX_FILE']
tmp_dir = os.environ['TMP_DIR']
services_dir = '/etc/swarm-services'
base_url = f'https://super-protocol.github.io/swarm-cloud-services/{services_tag}'

with open(index_file) as f:
    data = json.load(f)

services = data.get('services') or []
if not services:
    print('ERROR: services index has no entries', flush=True)
    raise SystemExit(1)

os.makedirs(services_dir, exist_ok=True)

for entry in services:
    service_name = entry['name']
    filename = entry['file']
    expected_sha = entry['sha256']
    dest = os.path.join(tmp_dir, filename)
    url = f'{base_url}/{filename}'

    subprocess.run(['curl', '-sfL', '-o', dest, url], check=True)

    actual_sha = hashlib.sha256(open(dest, 'rb').read()).hexdigest()
    if actual_sha != expected_sha:
        print(
            f'ERROR: sha256 mismatch for {filename}: expected {expected_sha}, got {actual_sha}',
            flush=True,
        )
        raise SystemExit(1)

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
        if [[ "$HOST_AGENT_TAG" == "develop" || "$HOST_AGENT_TAG" == "main" ]]; then
            RELEASE_TAG="host-agent-$HOST_AGENT_TAG"
            FILENAME="swarm-host-agent-${HOST_AGENT_TAG}-linux-amd64.tar.gz"
        elif [[ "$HOST_AGENT_TAG" == release-* ]]; then
            RELEASE_TAG="$HOST_AGENT_TAG"
            FILENAME="swarm-host-agent-${RELEASE_TAG}-linux-amd64.tar.gz"
        elif [[ "$HOST_AGENT_TAG" == host-agent-* ]]; then
            VERSION="${HOST_AGENT_TAG#host-agent-}"
            RELEASE_TAG="release-$VERSION"
            FILENAME="swarm-host-agent-${RELEASE_TAG}-linux-amd64.tar.gz"
        else
            RELEASE_TAG="release-$HOST_AGENT_TAG"
            FILENAME="swarm-host-agent-${RELEASE_TAG}-linux-amd64.tar.gz"
        fi
        TMP=$(mktemp -d)
        download_github_asset "Super-Protocol" "swarm-cloud" "$RELEASE_TAG" "$FILENAME" "$TMP/host-agent.tar.gz"
        tar xzf "$TMP/host-agent.tar.gz" -C "$TMP"
        EXTRACT_DIR=$(ls -1 "$TMP" | grep -v 'host-agent\.tar\.gz' | head -1)
        install -m 755 "$TMP/$EXTRACT_DIR/swarm-host-agent" /usr/local/bin/swarm-host-agent
        mkdir -p /etc/swarm
        cp "$TMP/$EXTRACT_DIR/host-agent.yaml" /etc/swarm/host-agent.yaml
        rm -rf "$TMP"
        log "swarm-host-agent $RELEASE_TAG installed"
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
SWARM_CLOUD_API_TAG=${SWARM_CLOUD_API_TAG}
SWARM_CLOUD_UI_TAG=${SWARM_CLOUD_UI_TAG}
AUTH_SERVICE_TAG=${AUTH_SERVICE_TAG}
GATEKEEPER_S3_IMAGE=${GATEKEEPER_S3_IMAGE}
GATEKEEPER_HARBOR_IMAGE=${GATEKEEPER_HARBOR_IMAGE}
EOF

# Generate /etc/swarm/swarm-host-agent.env for swarm-host-agent.service EnvironmentFile (idempotent)
log "generating /etc/swarm/swarm-host-agent.env..."
cat > /etc/swarm/swarm-host-agent.env << EOF
SWARM_CLOUD_API_TAG=${SWARM_CLOUD_API_TAG}
SWARM_CLOUD_UI_TAG=${SWARM_CLOUD_UI_TAG}
AUTH_SERVICE_TAG=${AUTH_SERVICE_TAG}
PKI_AUTHORITY_TAG=${PKI_AUTHORITY_TAG}
GATEKEEPER_S3_IMAGE=${GATEKEEPER_S3_IMAGE}
GATEKEEPER_HARBOR_IMAGE=${GATEKEEPER_HARBOR_IMAGE}
EOF

log "swarm-init completed successfully"
