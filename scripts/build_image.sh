#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SWARM_CLOUD_DIR="../swarm-cloud"
SCHEMA_SRC="${SWARM_CLOUD_DIR}/apps/swarm-node-e2e/fixtures/schema.yaml"
SCHEMA_SHA256="cf20aa0329c0738c5995a7e3e36b1cc16f6714dfcd94ec795954e19430c76715"

if [[ ! -d "$SWARM_CLOUD_DIR" ]]; then
  echo "Directory ${SWARM_CLOUD_DIR} not found." >&2
  echo "Clone swarm-cloud next to this repository:" >&2
  echo "  git clone git@github.com:Super-Protocol/swarm-cloud.git ${SWARM_CLOUD_DIR}" >&2
  exit 1
fi

if [[ ! -f "$SCHEMA_SRC" ]]; then
  echo "File ${SCHEMA_SRC} not found." >&2
  exit 1
fi

mkdir -p swarm-db-schema
cp "$SCHEMA_SRC" swarm-db-schema/schema.yaml
printf '%s  %s\n' "$SCHEMA_SHA256" swarm-db-schema/schema.yaml | shasum -a 256 -c

if ! docker buildx inspect insecure-builder >/dev/null 2>&1; then
  docker buildx create --use --name insecure-builder \
    --buildkitd-flags '--allow-insecure-entitlement security.insecure'
else
  docker buildx use insecure-builder
fi

docker buildx build \
  -t sp-vm \
  --platform linux/amd64 \
  --allow security.insecure \
  --build-context swarm_db_schema="$(pwd)/swarm-db-schema" \
  --build-arg SP_VM_BUILD_TYPE=debug \
  --build-arg SP_VM_IMAGE_VERSION=local-schema-test \
  --build-arg S3_BUCKET=local \
  src \
  --output type=local,dest=./out
