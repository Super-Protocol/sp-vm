#!/bin/bash
set -euo pipefail

# Simple CLI to manage Swarm DB entities.
# Usage examples:
#   swarm-cli.sh create ClusterPolicies my-policy --minSize=1 --maxSize=3 --maxClusters=1
#   swarm-cli.sh create ClusterServices my-service --name=redis --cluster_policy=redis \
#       --version=1.0.0 --location=/etc/swarm-cloud/services/redis
#
# Notes:
# - DB connection can be configured via env: DB_HOST, DB_PORT, DB_USER, DB_NAME
# - For ClusterServices, if --id is not provided, id defaults to "<cluster_policy>:<name>"
# - For ClusterServices, if --location not provided, defaults to "/etc/swarm-cloud/services/<name>"
# - When creating ClusterServices, if "<location>/manifest.yaml" exists it will be read,
#   the 'init' command will be removed from the 'commands:' block, and the resulting YAML
#   will be stored (base64-encoded) in the 'manifest' column.

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_NAME=${DB_NAME:-swarmdb}

usage() {
  cat <<EOF
Usage:
  $0 create ClusterPolicies <id> [--minSize=N] [--maxSize=N] [--maxClusters=N]
  $0 create ClusterServices [<id>] --name=NAME --cluster_policy=POLICY [--version=1.0.0] [--location=/etc/swarm-cloud/services/NAME]

Environment:
  DB_HOST (default: 127.0.0.1)
  DB_PORT (default: 3306)
  DB_USER (default: root)
  DB_NAME (default: swarmdb)
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

base64_encode_nnl() {
  # Encode stdin to base64 without newlines
  if base64 --help 2>&1 | grep -q '\-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

filter_manifest_remove_init() {
  # $1: path to manifest.yaml
  sed '/^commands:/,/^[^[:space:]]/ { /^[[:space:]]*-[[:space:]]*init[[:space:]]*$/d }' "$1"
}

create_cluster_policies() {
  local ID="$1"; shift
  local MIN_SIZE="${ARGS[minSize]:-}"
  local MAX_SIZE="${ARGS[maxSize]:-}"
  local MAX_CLUSTERS="${ARGS[maxClusters]:-}"

  if [[ -z "$ID" ]]; then
    echo "ClusterPolicies id is required." >&2
    exit 1
  fi

  local fields=(id)
  local values=("$ID")
  local updates=("id=VALUES(id)")

  if [[ -n "${MIN_SIZE}" ]]; then
    fields+=("minSize"); values+=("$MIN_SIZE"); updates+=("minSize=VALUES(minSize)")
  fi
  if [[ -n "${MAX_SIZE}" ]]; then
    fields+=("maxSize"); values+=("$MAX_SIZE"); updates+=("maxSize=VALUES(maxSize)")
  fi
  if [[ -n "${MAX_CLUSTERS}" ]]; then
    fields+=("maxClusters"); values+=("$MAX_CLUSTERS"); updates+=("maxClusters=VALUES(maxClusters)")
  fi

  local fields_csv values_csv updates_csv
  fields_csv=$(IFS=, ; echo "${fields[*]}")
  # Quote values for SQL
  local quoted_vals=()
  for v in "${values[@]}"; do quoted_vals+=("'${v}'"); done
  values_csv=$(IFS=, ; echo "${quoted_vals[*]}")
  updates_csv=$(IFS=, ; echo "${updates[*]}")

  mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" --protocol=tcp "$DB_NAME" <<SQL
INSERT INTO ClusterPolicies (${fields_csv}) VALUES (${values_csv})
ON DUPLICATE KEY UPDATE ${updates_csv};
SQL
  echo "ClusterPolicies '${ID}' upserted."
}

create_cluster_services() {
  local ID="${ARGS[id]:-}"
  local NAME="${ARGS[name]:-}"
  local CLUSTER_POLICY="${ARGS[cluster_policy]:-}"
  local VERSION="${ARGS[version]:-1.0.0}"
  local LOCATION="${ARGS[location]:-}"

  if [[ -z "$NAME" || -z "$CLUSTER_POLICY" ]]; then
    echo "ClusterServices requires --name and --cluster_policy." >&2
    exit 1
  fi
  if [[ -z "$LOCATION" ]]; then
    LOCATION="/etc/swarm-cloud/services/${NAME}"
  fi
  if [[ -z "$ID" ]]; then
    ID="${CLUSTER_POLICY}:${NAME}"
  fi

  local MANIFEST_SET="SET @manifest = NULL;"
  local manifest_path="${LOCATION%/}/manifest.yaml"
  if [[ -f "$manifest_path" ]]; then
    local filtered
    filtered="$(filter_manifest_remove_init "$manifest_path")"
    # Encode to base64 and decode inside SQL to store plain YAML
    local b64
    b64="$(printf "%s" "$filtered" | base64_encode_nnl)"
    MANIFEST_SET="SET @manifest = FROM_BASE64('${b64}');"
  fi

  mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" --protocol=tcp "$DB_NAME" <<SQL
${MANIFEST_SET}
INSERT INTO ClusterServices (id, cluster_policy, name, version, location, hash, manifest, updated_ts)
VALUES (
  '$ID',
  '$CLUSTER_POLICY',
  '$NAME',
  '$VERSION',
  CONCAT('dir://', '$LOCATION'),
  NULL,
  @manifest,
  UNIX_TIMESTAMP()*1000
)
ON DUPLICATE KEY UPDATE
  version=VALUES(version),
  location=VALUES(location),
  manifest=VALUES(manifest),
  updated_ts=VALUES(updated_ts);
SQL
  echo "ClusterServices '${ID}' upserted."
}

declare -A ARGS=()

main() {
  require_cmd mysql
  require_cmd base64
  require_cmd sed

  if [[ $# -lt 2 ]]; then
    usage; exit 1
  fi
  local ACTION="$1"; shift
  local ENTITY="$1"; shift

  local POSITIONAL_ID=""
  # Parse remaining args as either positional id (first non key=value) or key=value/--key=value
  while (( $# )); do
    case "$1" in
      --*=*)
        key="${1%%=*}"; key="${key#--}"
        val="${1#*=}"
        ARGS["$key"]="$val"
        ;;
      *=*)
        key="${1%%=*}"
        val="${1#*=}"
        ARGS["$key"]="$val"
        ;;
      *)
        if [[ -z "$POSITIONAL_ID" ]]; then
          POSITIONAL_ID="$1"
        fi
        ;;
    esac
    shift
  done

  # If a positional id was provided, prefer it unless --id was set
  if [[ -n "$POSITIONAL_ID" && -z "${ARGS[id]:-}" ]]; then
    ARGS[id]="$POSITIONAL_ID"
  fi

  case "$ACTION:$ENTITY" in
    create:ClusterPolicies)
      create_cluster_policies "${ARGS[id]:-}"
      ;;
    create:ClusterServices)
      create_cluster_services
      ;;
    *)
      echo "Unsupported command: $ACTION $ENTITY" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
