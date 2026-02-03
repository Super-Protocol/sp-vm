#!/bin/bash
set -euo pipefail

# This script bootstraps the domain-initializer service into SwarmDB via swarm-cli.
# Run it INSIDE the container. Assumes python3 and swarm-cli.py are available.
#
# Notes:
# - The service manifest is expected to be available on all nodes at:
#     ${LOCATION_PATH}/manifest.yaml
#   If you don't have a manifest yet, set ALLOW_MISSING_MANIFEST=1 to still
#   register the ClusterService (manifest will be stored as NULL).
# - domain-initializer dependencies are expected to be expressed in the manifest
#   (stateExpr/commands) and handled by provision workers.

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-domain-initializer}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-domain-initializer}
CLUSTER_ID=${CLUSTER_ID:-domain-initializer}

# Location stored in ClusterServices; must exist on all nodes.
# The service provisioner (manifest.yaml + main.py) is baked into the image under
# /etc/swarm-cloud/services/${SERVICE_NAME}.
LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-cloud/services/${SERVICE_NAME}}
MANIFEST_PATH=${MANIFEST_PATH:-${LOCATION_PATH}/manifest.yaml}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

ALLOW_MISSING_MANIFEST=${ALLOW_MISSING_MANIFEST:-0}

if [ ! -f "$MANIFEST_PATH" ]; then
	if [ "$ALLOW_MISSING_MANIFEST" = "1" ] || [ "$ALLOW_MISSING_MANIFEST" = "true" ]; then
		echo "Warning: manifest not found at: $MANIFEST_PATH (continuing due to ALLOW_MISSING_MANIFEST=1)" >&2
	else
		echo "Manifest not found at: $MANIFEST_PATH" >&2
		echo "If you want to register the service without a manifest, set ALLOW_MISSING_MANIFEST=1" >&2
		exit 1
	fi
fi

echo "Ensuring ClusterPolicy '$CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
	python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$CLUSTER_POLICY" >/dev/null 2>&1; then
	echo "ClusterPolicy '$CLUSTER_POLICY' already exists, skipping creation."
else
	echo "Creating ClusterPolicy '$CLUSTER_POLICY'..."
	DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
		python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$CLUSTER_POLICY" --minSize=1 --maxSize=1 --maxClusters=1
fi

echo "Ensuring ClusterService '$SERVICE_PK'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
	python3 "$(dirname "$0")/swarm-cli.py" get ClusterServices "$SERVICE_PK" >/dev/null 2>&1; then
	echo "ClusterService '$SERVICE_PK' already exists, skipping creation."
else
	echo "Creating ClusterService '$SERVICE_PK'..."
	DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
		python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SERVICE_PK" \
			--name="$SERVICE_NAME" \
			--cluster_policy="$CLUSTER_POLICY" \
			--version="$SERVICE_VERSION" \
			--location="$LOCATION_PATH"
fi

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
