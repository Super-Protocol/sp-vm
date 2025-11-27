#!/bin/bash
set -euo pipefail

# This script bootstraps the rke2 service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.
#
# Note:
# - The rke2 manifest and main.py should be available inside the container at:
#     /etc/swarm-services/rke2/manifest.yaml and /etc/swarm-services/rke2/main.py
#   (mount or copy them similarly to the wireguard service)
#
# - rke2 depends on a WireGuard cluster existing and sharing nodes with it.
#   When bootstrapping WireGuard, prefer ClusterPolicy id 'wireguard' to match rke2's stateExpr.

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-rke2}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-rke2}
CLUSTER_ID=${CLUSTER_ID:-rke2}

# Path to manifest file INSIDE the container (configs are mounted to /configs)
MANIFEST_PATH=${MANIFEST_PATH:-/etc/swarm-services/${SERVICE_NAME}/manifest.yaml}
LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-services/${SERVICE_NAME}}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

CLI="$(dirname "$0")/swarm-cli.sh"
echo "Creating/Updating ClusterPolicies '$CLUSTER_POLICY'..."
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$CLUSTER_POLICY"

echo "Creating/Updating ClusterServices '$SERVICE_PK'..."
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SERVICE_PK" --name="$SERVICE_NAME" --cluster_policy="$CLUSTER_POLICY" --version="$SERVICE_VERSION" --location="$LOCATION_PATH"

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
