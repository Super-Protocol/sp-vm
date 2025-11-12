#!/bin/bash
set -euo pipefail

# This script bootstraps the wireguard service into SwarmDB via mysql client.
# Run it INSIDE the container. Assumes mysql client is available.

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

# Service descriptors
SERVICE_NAME=${SERVICE_NAME:-wireguard}
SERVICE_VERSION=${SERVICE_VERSION:-1.0.0}
CLUSTER_POLICY=${CLUSTER_POLICY:-network}
CLUSTER_ID=${CLUSTER_ID:-wg}

# Path to manifest file INSIDE the container (configs are mounted to /configs)
MANIFEST_PATH=${MANIFEST_PATH:-/var/lib/swarm-svc/${SERVICE_NAME}/manifest.yaml}
LOCATION_PATH=${LOCATION_PATH:-/var/lib/swarm-svc/${SERVICE_NAME}}

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Manifest not found at: $MANIFEST_PATH" >&2
  exit 1
fi

echo "Encoding manifest from: $MANIFEST_PATH"
MANIFEST_B64=$(base64 -w 0 "$MANIFEST_PATH" 2>/dev/null || base64 "$MANIFEST_PATH")

echo "Applying SQL to bootstrap service '$SERVICE_NAME' in cluster '$CLUSTER_ID' (policy '$CLUSTER_POLICY')"

mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" --protocol=tcp "$DB_NAME" <<SQL
-- 1) Ensure cluster policy exists
INSERT INTO ClusterPolicies (id) VALUES ('$CLUSTER_POLICY')
ON DUPLICATE KEY UPDATE id = VALUES(id);

-- 2) Ensure cluster exists (under policy)
INSERT INTO Clusters (id, cluster_policy, created_ts)
VALUES ('$CLUSTER_ID', '$CLUSTER_POLICY', UNIX_TIMESTAMP()*1000)
ON DUPLICATE KEY UPDATE cluster_policy = VALUES(cluster_policy), deleted_ts = NULL, updated_ts = UNIX_TIMESTAMP()*1000;

-- 3) Insert/Update service with manifest
SET @manifest = FROM_BASE64('$MANIFEST_B64');
INSERT INTO ClusterServices (id, cluster_policy, name, version, location, hash, manifest, updated_ts)
VALUES (
  '$SERVICE_NAME',
  '$CLUSTER_POLICY',
  '$SERVICE_NAME',
  '$SERVICE_VERSION',
  CONCAT('dir://', '$LOCATION_PATH'),
  NULL,
  @manifest,
  UNIX_TIMESTAMP()*1000
)
ON DUPLICATE KEY UPDATE version=VALUES(version), location=VALUES(location), manifest=VALUES(manifest), updated_ts=VALUES(updated_ts);

-- 4) Add local node to cluster to trigger provisioning immediately
INSERT INTO ClusterNodes (id, cluster, node, created_ts)
VALUES (
  CONCAT('$CLUSTER_ID:', (SELECT node_id FROM localnodepointer LIMIT 1)),
  '$CLUSTER_ID',
  (SELECT node_id FROM localnodepointer LIMIT 1),
  UNIX_TIMESTAMP()*1000
)
ON DUPLICATE KEY UPDATE deleted_ts = NULL;
SQL

echo "Done. The provision worker will reconcile '$SERVICE_NAME' shortly."
