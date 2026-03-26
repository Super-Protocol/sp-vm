#!/bin/bash
set -euo pipefail

# This script bootstraps the cockroachdb service into SwarmDB via swarm-cli.
# Run it INSIDE the container. Assumes mysql client and swarm-cli.py are available.
#
# Notes:
# - The cockroachdb manifest and main.py are provided by the image at:
#     /etc/swarm-services/cockroachdb/{manifest.yaml, main.py}
#   We do not reimplement any logic here, only register ClusterPolicy and ClusterService.
# - cockroachdb depends on WireGuard as expressed in its own manifest and provision plugin.
#

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-cockroachdb}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-cockroachdb}
CLUSTER_ID=${CLUSTER_ID:-cockroachdb}
CLUSTER_MIN_SIZE=${CLUSTER_MIN_SIZE:-3}
CLUSTER_MAX_SIZE=${CLUSTER_MAX_SIZE:-3}
CLUSTER_MAX_CLUSTERS=${CLUSTER_MAX_CLUSTERS:-1}

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

echo "Ensuring ClusterPolicy '$CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$CLUSTER_POLICY" >/dev/null 2>&1; then
  echo "ClusterPolicy '$CLUSTER_POLICY' already exists, skipping creation."
else
  echo "Creating ClusterPolicy '$CLUSTER_POLICY'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$CLUSTER_POLICY" --minSize="$CLUSTER_MIN_SIZE" --maxSize="$CLUSTER_MAX_SIZE" --maxClusters="$CLUSTER_MAX_CLUSTERS"
fi

MEASUREMENT_RULE_ID="${CLUSTER_POLICY}:latency"
echo "Ensuring ClusterPolicyMeasurementRule '$MEASUREMENT_RULE_ID'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicyMeasurementRules "$MEASUREMENT_RULE_ID" >/dev/null 2>&1; then
  echo "ClusterPolicyMeasurementRule '$MEASUREMENT_RULE_ID' already exists, skipping creation."
else
  echo "Creating ClusterPolicyMeasurementRule '$MEASUREMENT_RULE_ID'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicyMeasurementRules "$MEASUREMENT_RULE_ID" \
      --name="latency" \
      --cluster_policy="$CLUSTER_POLICY" \
      --measurement_type="latency" \
      --condition="less_than" \
      --value="10.0" \
      --jitter=10
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
