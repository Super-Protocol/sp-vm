#!/bin/bash
set -euo pipefail

# This script bootstraps the tee-entry-certificates-service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.
#
# Note:
# - The service is a Node.js app installed into the VM image under:
#     /usr/local/lib/sp-swarm-services/apps/tee-entry-certificates-service
#   There is no provision manifest; we register the location so SwarmDB tracks it.
#

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-sp-tee-entry-certificates-service}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-sp-tee-entry-certificates-service}
CLUSTER_ID=${CLUSTER_ID:-tee-entry-certificates-service}

# Location and manifest inside the container (provision plugin location)
LOCATION_DIR_NAME=${LOCATION_DIR_NAME:-$SERVICE_NAME}
LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-services/${LOCATION_DIR_NAME}}
MANIFEST_PATH=${MANIFEST_PATH:-${LOCATION_PATH}/manifest.yaml}
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
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SERVICE_PK" --name="$SERVICE_NAME" --cluster_policy="$CLUSTER_POLICY" --version="$SERVICE_VERSION" --location="$LOCATION_PATH" --omit-command-init

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
