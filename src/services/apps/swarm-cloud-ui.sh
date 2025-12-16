#!/usr/bin/env bash

set -euo pipefail

# This script starts the swarm-cloud-ui frontend locally in development mode.
# It uses the swarm-cloud monorepo that is vendored into this repository under
# src/repos/swarm-cloud.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_CLOUD_DIR="${SCRIPT_DIR}/../../repos/swarm-cloud"

if [[ ! -d "${SWARM_CLOUD_DIR}" ]]; then
  echo "swarm-cloud repository directory not found at: ${SWARM_CLOUD_DIR}" >&2
  exit 1
fi

cd "${SWARM_CLOUD_DIR}"

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


