#!/bin/bash
set -euo pipefail

# This script bootstraps the redis service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.
#
# Note:
# - The redis manifest and main.py are provided by the image at:
#     /etc/swarm-cloud/services/redis/{manifest.yaml, main.py}
#   This script only registers service records in SwarmDB.
# - redis depends on a WireGuard cluster existing and sharing nodes with it.
#   When bootstrapping WireGuard, prefer ClusterPolicy id 'wireguard' to match redis's stateExpr.

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
REDIS_SERVICE_NAME=${REDIS_SERVICE_NAME:-redis}
REDIS_SERVICE_VERSION=${REDIS_SERVICE_VERSION:-1.0.0}
REDIS_CLUSTER_POLICY=${REDIS_CLUSTER_POLICY:-redis}
REDIS_MAX_SIZE=${REDIS_MAX_SIZE:-5}

SENTINEL_SERVICE_NAME=${SENTINEL_SERVICE_NAME:-redis-sentinel}
SENTINEL_SERVICE_VERSION=${SENTINEL_SERVICE_VERSION:-$REDIS_SERVICE_VERSION}
SENTINEL_CLUSTER_POLICY=${SENTINEL_CLUSTER_POLICY:-redis-sentinel}
SENTINEL_MAX_SIZE=${SENTINEL_MAX_SIZE:-3}

# Location stored in ClusterServices; must exist on all nodes (baked into image)
REDIS_LOCATION_PATH=${REDIS_LOCATION_PATH:-/etc/swarm-cloud/services/${REDIS_SERVICE_NAME}}
REDIS_MANIFEST_PATH=${REDIS_MANIFEST_PATH:-${REDIS_LOCATION_PATH}/manifest.yaml}
SENTINEL_LOCATION_PATH=${SENTINEL_LOCATION_PATH:-/etc/swarm-cloud/services/${SENTINEL_SERVICE_NAME}}
SENTINEL_MANIFEST_PATH=${SENTINEL_MANIFEST_PATH:-${SENTINEL_LOCATION_PATH}/manifest.yaml}
REDIS_SERVICE_PK="${REDIS_CLUSTER_POLICY}:${REDIS_SERVICE_NAME}"
SENTINEL_SERVICE_PK="${SENTINEL_CLUSTER_POLICY}:${SENTINEL_SERVICE_NAME}"

if [ ! -f "$REDIS_MANIFEST_PATH" ]; then
  echo "Redis manifest not found at: $REDIS_MANIFEST_PATH" >&2
  exit 1
fi

if [ ! -f "$SENTINEL_MANIFEST_PATH" ]; then
  echo "Redis Sentinel manifest not found at: $SENTINEL_MANIFEST_PATH" >&2
  exit 1
fi

echo "Ensuring ClusterPolicy '$REDIS_CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$REDIS_CLUSTER_POLICY" >/dev/null 2>&1; then
  echo "ClusterPolicy '$REDIS_CLUSTER_POLICY' already exists, skipping creation."
else
  echo "Creating ClusterPolicy '$REDIS_CLUSTER_POLICY'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$REDIS_CLUSTER_POLICY" --minSize=1 --maxSize="$REDIS_MAX_SIZE" --maxClusters=1
fi

echo "Ensuring ClusterPolicy '$SENTINEL_CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$SENTINEL_CLUSTER_POLICY" >/dev/null 2>&1; then
  echo "ClusterPolicy '$SENTINEL_CLUSTER_POLICY' already exists, skipping creation."
else
  echo "Creating ClusterPolicy '$SENTINEL_CLUSTER_POLICY'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$SENTINEL_CLUSTER_POLICY" --minSize=1 --maxSize="$SENTINEL_MAX_SIZE" --maxClusters=1
fi

echo "Ensuring ClusterService '$REDIS_SERVICE_PK'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterServices "$REDIS_SERVICE_PK" >/dev/null 2>&1; then
  echo "ClusterService '$REDIS_SERVICE_PK' already exists, skipping creation."
else
  echo "Creating ClusterService '$REDIS_SERVICE_PK'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$REDIS_SERVICE_PK" --name="$REDIS_SERVICE_NAME" --cluster_policy="$REDIS_CLUSTER_POLICY" --version="$REDIS_SERVICE_VERSION" --location="$REDIS_LOCATION_PATH" --omit-command-init
fi

echo "Ensuring ClusterService '$SENTINEL_SERVICE_PK'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterServices "$SENTINEL_SERVICE_PK" >/dev/null 2>&1; then
  echo "ClusterService '$SENTINEL_SERVICE_PK' already exists, skipping creation."
else
  echo "Creating ClusterService '$SENTINEL_SERVICE_PK'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$SENTINEL_SERVICE_PK" --name="$SENTINEL_SERVICE_NAME" --cluster_policy="$SENTINEL_CLUSTER_POLICY" --version="$SENTINEL_SERVICE_VERSION" --location="$SENTINEL_LOCATION_PATH" --omit-command-init
fi

echo "Done. The provision worker will reconcile '$REDIS_SERVICE_NAME' shortly."
