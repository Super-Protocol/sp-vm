#!/usr/bin/env bash

set -euo pipefail

# This script starts the swarm-cloud-ui frontend in the same layout that the VM image uses.
# According to build_swarm_cloud.sh and the Dockerfile, the built UI is published to:
#   /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui
# All dependencies are installed at image build time in build_swarm_cloud.sh; this script
# MUST NOT run pnpm install or modify node_modules at runtime.

SWARM_CLOUD_ROOT="/usr/local/lib/swarm-cloud"
SWARM_CLOUD_UI_DIR="${SWARM_CLOUD_ROOT}/dist/apps/swarm-cloud-ui"

cd "${SWARM_CLOUD_UI_DIR}"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is not installed or not in PATH. Please install Node.js first." >&2
  exit 1
fi

LISTEN_INTERFACE="${LISTEN_INTERFACE:-0.0.0.0}"
SWARM_CLOUD_UI_PORT="${SWARM_CLOUD_UI_PORT:-3000}"

echo "Starting swarm-cloud-ui in development mode with Next.js (pnpm deploy layout)..."
echo "  Host: ${LISTEN_INTERFACE}"
echo "  Port: ${SWARM_CLOUD_UI_PORT}"

NODE_ENV=development exec node \
  node_modules/next/dist/bin/next dev \
  --hostname "${LISTEN_INTERFACE}" \
  --port "${SWARM_CLOUD_UI_PORT}"
