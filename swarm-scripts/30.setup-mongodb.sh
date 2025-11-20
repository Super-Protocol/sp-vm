#!/bin/bash
set -euo pipefail

# This script bootstraps the mongodb service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.
#
# Note:
# - Source service files should be available at:
#     /sp/swarm/services/apps/mongodb/{manifest.yaml, main.py}
# - Files will be copied to a writable destination before registering the service:
#     /var/lib/swarm/services/apps/mongodb
#
# - mongodb depends on a WireGuard cluster existing and sharing nodes with it.
#   When bootstrapping WireGuard, prefer ClusterPolicy id 'wireguard' to match mongodb's stateExpr.
#

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-mongodb}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-mongodb}
CLUSTER_ID=${CLUSTER_ID:-mongodb}

# Paths inside the container
SRC_PATH=${SRC_PATH:-/sp/swarm/services/apps/${SERVICE_NAME}}
DEST_PATH=${DEST_PATH:-/var/lib/swarm/services/apps/${SERVICE_NAME}}
# Manifest path used only for sanity check
MANIFEST_PATH=${MANIFEST_PATH:-${SRC_PATH}/manifest.yaml}
# Location stored in ClusterServices; should be WRITABLE for runtime (chmod, etc.)
LOCATION_PATH=${LOCATION_PATH:-${DEST_PATH}}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

echo "Syncing '${SERVICE_NAME}' service files to writable location: $DEST_PATH"
mkdir -p "$DEST_PATH"
cp -a "${SRC_PATH}/." "$DEST_PATH/"
# Ensure entrypoint is executable (swarm may still attempt chmod, but pre-marking helps)
if [ -f "${DEST_PATH}/main.py" ]; then
  chmod +x "${DEST_PATH}/main.py" || true
fi

CLI="$(dirname "$0")/swarm-cli.sh"
echo "Creating/Updating ClusterPolicies '$CLUSTER_POLICY'..."
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  bash "$CLI" create ClusterPolicies "$CLUSTER_POLICY" --minSize=1 --maxSize=5 --maxClusters=1

echo "Creating/Updating ClusterServices '$SERVICE_PK'..."
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  bash "$CLI" create ClusterServices "$SERVICE_PK" --name="$SERVICE_NAME" --cluster_policy="$CLUSTER_POLICY" --version="$SERVICE_VERSION" --location="$LOCATION_PATH"

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
