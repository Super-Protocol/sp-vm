#!/bin/bash
set -euo pipefail

# This script bootstraps the swarm-gatekeeper-s3 service into SwarmDB via swarm-cli.
# Run it INSIDE the container. Assumes mysql client and swarm-cli.py are available.
#
# Notes:
# - The swarm-gatekeeper-s3 manifest and main.py are provided by the image at:
#     /etc/swarm-services/swarm-gatekeeper-s3/{manifest.yaml, main.py}
#   This script only registers ClusterPolicy and ClusterService records in SwarmDB.
# - swarm-gatekeeper-s3 has affinity rules towards wireguard and minio clusters.
# - This script is intentionally numbered after wireguard (10) and minio (67).

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-swarm-gatekeeper-s3}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-gatekeeper-s3}
CLUSTER_MIN_SIZE=${CLUSTER_MIN_SIZE:-1}
CLUSTER_MAX_SIZE=${CLUSTER_MAX_SIZE:-1}
CLUSTER_MAX_CLUSTERS=${CLUSTER_MAX_CLUSTERS:-1}

# Location and manifest inside the container.
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

AFFINITY_RULE_ID="${CLUSTER_POLICY}:wireguard-affinity"
echo "Ensuring ClusterPolicyAffinityRule '$AFFINITY_RULE_ID'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicyAffinityRules "$AFFINITY_RULE_ID" >/dev/null 2>&1; then
  echo "ClusterPolicyAffinityRule '$AFFINITY_RULE_ID' already exists, skipping creation."
else
  echo "Creating ClusterPolicyAffinityRule '$AFFINITY_RULE_ID'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicyAffinityRules "$AFFINITY_RULE_ID" \
      --name="wireguard-affinity" \
      --cluster_policy="$CLUSTER_POLICY" \
      --target_cluster_policy="wireguard" \
      --affinity_type="positive"
fi

AFFINITY_RULE_ID="${CLUSTER_POLICY}:minio-affinity"
echo "Ensuring ClusterPolicyAffinityRule '$AFFINITY_RULE_ID'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicyAffinityRules "$AFFINITY_RULE_ID" >/dev/null 2>&1; then
  echo "ClusterPolicyAffinityRule '$AFFINITY_RULE_ID' already exists, skipping creation."
else
  echo "Creating ClusterPolicyAffinityRule '$AFFINITY_RULE_ID'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicyAffinityRules "$AFFINITY_RULE_ID" \
      --name="minio-affinity" \
      --cluster_policy="$CLUSTER_POLICY" \
      --target_cluster_policy="minio" \
      --affinity_type="positive"
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
