#!/bin/bash
set -euo pipefail

# This script bootstraps the hw-measurement service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.
#
# Note:
# - The hw-measurement manifest and main.py should be available inside the container at:
#     /etc/swarm-services/hw-measurement/manifest.yaml and /etc/swarm-services/hw-measurement/main.py
#   (mount or copy them similarly to the wireguard service)
#
# - hw-measurement depends on a WireGuard cluster existing and sharing nodes with it.
#   When bootstrapping WireGuard, prefer ClusterPolicy id 'wireguard' to match hw-measurement's stateExpr.

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-hw-measurement}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-hw-measurement}
CLUSTER_ID=${CLUSTER_ID:-hw-measurement}

# Path to manifest file INSIDE the container (configs are mounted to /configs)
MANIFEST_PATH=${MANIFEST_PATH:-/etc/swarm-services/${SERVICE_NAME}/manifest.yaml}
LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-services/${SERVICE_NAME}}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

CLI="$(dirname "$0")/swarm-cli.sh"
echo "Ensuring ClusterPolicy '$CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$CLUSTER_POLICY" >/dev/null 2>&1; then
  echo "ClusterPolicy '$CLUSTER_POLICY' already exists, skipping creation."
else
  echo "Creating ClusterPolicy '$CLUSTER_POLICY'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$CLUSTER_POLICY" --minSize=1 --maxSize=3 --maxClusters=1
fi

echo "Ensuring ClusterService '$SERVICE_PK'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterServices "$SERVICE_PK" >/dev/null 2>&1; then
  echo "ClusterService '$SERVICE_PK' already exists, skipping creation."
else
  echo "Creating ClusterService '$SERVICE_PK'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SERVICE_PK" --name="$SERVICE_NAME" --cluster_policy="$CLUSTER_POLICY" --version="$SERVICE_VERSION" --location="$LOCATION_PATH"
fi

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
