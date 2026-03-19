#!/bin/bash

set -euo pipefail

# This script bootstraps the swarm-cloud-api service into SwarmDB via swarm-cli.
# Run it INSIDE the container. Assumes mysql client and swarm-cli.py are available.
#
# Notes:
# - The swarm-cloud-api manifest and main.py are provided by the image at:
#     /etc/swarm-services/swarm-cloud-api/{manifest.yaml, main.py}
#   We do not reimplement any logic here, only register ClusterPolicy and ClusterService.
# - swarm-cloud-api depends on CockroachDB, Redis, WireGuard and Knot as expressed
#   in its own manifest and provision plugin.
# - This script is intentionally numbered *after* redis (60), cockroachdb (61) and knot (62)
#   so you can run them in dependency order.
#

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-swarm-cloud-api}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-swarm-cloud-api}
CLUSTER_ID=${CLUSTER_ID:-swarm-cloud-api}
CLUSTER_MIN_SIZE=${CLUSTER_MIN_SIZE:-1}
CLUSTER_MAX_SIZE=${CLUSTER_MAX_SIZE:-1}
CLUSTER_MAX_CLUSTERS=${CLUSTER_MAX_CLUSTERS:-1}

# swarm-cloud-ui descriptors
UI_SERVICE_NAME=${UI_SERVICE_NAME:-swarm-cloud-ui}
UI_SERVICE_VERSION=${UI_SERVICE_VERSION:-1.0.0}
UI_CLUSTER_POLICY=${UI_CLUSTER_POLICY:-swarm-cloud-ui}
UI_CLUSTER_ID=${UI_CLUSTER_ID:-swarm-cloud-ui}
UI_CLUSTER_MIN_SIZE=${UI_CLUSTER_MIN_SIZE:-1}
UI_CLUSTER_MAX_SIZE=${UI_CLUSTER_MAX_SIZE:-1}
UI_CLUSTER_MAX_CLUSTERS=${UI_CLUSTER_MAX_CLUSTERS:-1}

# Location and manifest inside the container.
# IMPORTANT: This script runs only on one node. All nodes must have the same location available already
# (baked into the image), so we point to /etc/swarm-services/${SERVICE_NAME}.
LOCATION_PATH=${LOCATION_PATH:-/etc/swarm-services/${SERVICE_NAME}}
MANIFEST_PATH=${MANIFEST_PATH:-${LOCATION_PATH}/manifest.yaml}
SERVICE_PK="${CLUSTER_POLICY}:${SERVICE_NAME}"

UI_LOCATION_PATH=${UI_LOCATION_PATH:-/etc/swarm-services/${UI_SERVICE_NAME}}
UI_MANIFEST_PATH=${UI_MANIFEST_PATH:-${UI_LOCATION_PATH}/manifest.yaml}
UI_SERVICE_PK="${UI_CLUSTER_POLICY}:${UI_SERVICE_NAME}"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

if [ ! -f "$UI_MANIFEST_PATH" ]; then
  echo "Manifest not found at: $UI_MANIFEST_PATH" >&2
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

AFFINITY_RULE_ID="${CLUSTER_POLICY}:cockroachdb-affinity"
echo "Ensuring ClusterPolicyAffinityRule '$AFFINITY_RULE_ID'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicyAffinityRules "$AFFINITY_RULE_ID" >/dev/null 2>&1; then
  echo "ClusterPolicyAffinityRule '$AFFINITY_RULE_ID' already exists, skipping creation."
else
  echo "Creating ClusterPolicyAffinityRule '$AFFINITY_RULE_ID'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicyAffinityRules "$AFFINITY_RULE_ID" \
      --name="cockroachdb-affinity" \
      --cluster_policy="$CLUSTER_POLICY" \
      --target_cluster_policy="cockroachdb" \
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

echo "Ensuring ClusterPolicy '$UI_CLUSTER_POLICY'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicies "$UI_CLUSTER_POLICY" >/dev/null 2>&1; then
  echo "ClusterPolicy '$UI_CLUSTER_POLICY' already exists, skipping creation."
else
  echo "Creating ClusterPolicy '$UI_CLUSTER_POLICY'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicies "$UI_CLUSTER_POLICY" --minSize="$UI_CLUSTER_MIN_SIZE" --maxSize="$UI_CLUSTER_MAX_SIZE" --maxClusters="$UI_CLUSTER_MAX_CLUSTERS"
fi

UI_AFFINITY_RULE_ID="${UI_CLUSTER_POLICY}:redis-affinity"
echo "Ensuring ClusterPolicyAffinityRule '$UI_AFFINITY_RULE_ID'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterPolicyAffinityRules "$UI_AFFINITY_RULE_ID" >/dev/null 2>&1; then
  echo "ClusterPolicyAffinityRule '$UI_AFFINITY_RULE_ID' already exists, skipping creation."
else
  echo "Creating ClusterPolicyAffinityRule '$UI_AFFINITY_RULE_ID'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterPolicyAffinityRules "$UI_AFFINITY_RULE_ID" \
      --name="redis-affinity" \
      --cluster_policy="$UI_CLUSTER_POLICY" \
      --target_cluster_policy="redis" \
      --affinity_type="positive"
fi

echo "Ensuring ClusterService '$UI_SERVICE_PK'..."
if DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
  python3 "$(dirname "$0")/swarm-cli.py" get ClusterServices "$UI_SERVICE_PK" >/dev/null 2>&1; then
  echo "ClusterService '$UI_SERVICE_PK' already exists, skipping creation."
else
  echo "Creating ClusterService '$UI_SERVICE_PK'..."
  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
    python3 "$(dirname "$0")/swarm-cli.py" create ClusterServices "$UI_SERVICE_PK" --name="$UI_SERVICE_NAME" --cluster_policy="$UI_CLUSTER_POLICY" --version="$UI_SERVICE_VERSION" --location="$UI_LOCATION_PATH"
fi

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
