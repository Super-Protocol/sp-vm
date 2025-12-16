#!/usr/bin/env bash

set -euo pipefail

# This script starts the swarm-cloud-ui frontend in the same layout that the VM image uses.
# According to build_swarm_cloud.sh and the Dockerfile, the built UI is published to:
#   /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui
# We intentionally hardcode this path to match the runtime environment inside the VM.

cd /usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui

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

if [[ ! -d "node_modules" ]]; then
  echo "Installing Node.js dependencies with pnpm (this may take a while)..."
  pnpm install --frozen-lockfile
fi

echo "Starting swarm-cloud-ui dev server (Nx target swarm-cloud-ui:dev)..."
echo "Once started, the UI should be available at http://localhost:3000"
pnpm nx run swarm-cloud-ui:dev
