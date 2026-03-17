#!/bin/bash
set -euo pipefail

# This script bootstraps the pki-authority service into SwarmDB via swarm-cli.
# Run it INSIDE the container. Assumes swarm-cli.py is available.
#
# Note:
# - The pki-authority manifest and main.py should be available inside the container at:
#     /etc/swarm-services/pki-authority/manifest.yaml and /etc/swarm-services/pki-authority/main.py
#   (mount or copy them similarly to the wireguard service)
#
# - pki-authority depends on a WireGuard cluster existing and sharing nodes with it.
#   When bootstrapping WireGuard, prefer ClusterPolicy id 'wireguard' to match pki-authority's stateExpr.
DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-pki-authority}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-pki-authority}
CLUSTER_ID=${CLUSTER_ID:-pki-authority}

# Location and manifest inside the container.
# IMPORTANT: This script runs only on one node. All nodes must have the same location available already
# (baked into the image), so we point to /etc/swarm-services/${SERVICE_NAME}.
LOCATION_PATH=${LOCATION_PATH:-/sp/swarm/${SERVICE_NAME}}
#LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-services/${SERVICE_NAME}}
MANIFEST_PATH=${MANIFEST_PATH:-${LOCATION_PATH}/manifest.yaml}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

echo "Ensuring ClusterPolicy '$CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$CLUSTER_POLICY" >/dev/null 2>&1; then
  echo "ClusterPolicy '$CLUSTER_POLICY' already exists, updating parameters."
else
  echo "Creating ClusterPolicy '$CLUSTER_POLICY'..."
fi
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$CLUSTER_POLICY"

echo "Ensuring ClusterService '$SERVICE_PK'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterServices "$SERVICE_PK" >/dev/null 2>&1; then
  echo "ClusterService '$SERVICE_PK' already exists, updating parameters."
else
  echo "Creating ClusterService '$SERVICE_PK'..."
fi
DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SERVICE_PK" --name="$SERVICE_NAME" --cluster_policy="$CLUSTER_POLICY" --version="$SERVICE_VERSION" --location="$LOCATION_PATH"

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."