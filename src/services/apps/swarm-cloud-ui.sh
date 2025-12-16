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

if ! command -v corepack >/dev/null 2>&1; then
  echo "corepack is not installed or not in PATH. Please install Node.js (with corepack) first." >&2
  exit 1
fi

echo "Enabling corepack..."
corepack enable

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is not available via corepack. Please ensure your Node.js version supports pnpm via corepack." >&2
  exit 1
fi

LISTEN_INTERFACE="${LISTEN_INTERFACE:-0.0.0.0}"
SWARM_CLOUD_UI_PORT="${SWARM_CLOUD_UI_PORT:-3000}"

echo "Starting swarm-cloud-ui in production mode with Next.js..."
echo "  Host: ${LISTEN_INTERFACE}"
echo "  Port: ${SWARM_CLOUD_UI_PORT}"

exec pnpm exec next start \
  --hostname "${LISTEN_INTERFACE}" \
  --port "${SWARM_CLOUD_UI_PORT}"
