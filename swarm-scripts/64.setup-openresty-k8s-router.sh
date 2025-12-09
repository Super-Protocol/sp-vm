#!/bin/bash
set -euo pipefail

# This script bootstraps the openresty-k8s-router service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.
#
# Notes:
# - The openresty-k8s-router manifest and main.py are provided by the image at:
#     /etc/swarm-services/openresty-k8s-router/{manifest.yaml, main.py}
#   This script only registers service records in SwarmDB.
# - Convention: the router ClusterId should match the target RKE2 ClusterId.
#   The router uses this to find the corresponding RKE2 cluster in stateExpr.
#

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-openresty-k8s-router}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-openresty-k8s-router}
CLUSTER_ID=${CLUSTER_ID:-rke2}  # by default, bind router to the 'rke2' clusterId

# Location and manifest inside the container.
# IMPORTANT: This script runs only on one node. All nodes must have the same location available already
# (baked into the image), so we point to /etc/swarm-services/${SERVICE_NAME}.
LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-services/${SERVICE_NAME}}
MANIFEST_PATH=${MANIFEST_PATH:-${LOCATION_PATH}/manifest.yaml}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

CLI="$(dirname "$0")/swarm-cli.sh"
echo "Creating/Updating ClusterPolicies '$CLUSTER_POLICY'..."
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$CLUSTER_POLICY" --minSize=1 --maxSize=3 --maxClusters=0

echo "Creating/Updating ClusterServices '$SERVICE_PK'..."
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SERVICE_PK" --name="$SERVICE_NAME" --cluster_policy="$CLUSTER_POLICY" --version="$SERVICE_VERSION" --location="$LOCATION_PATH" --omit-command-init

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
