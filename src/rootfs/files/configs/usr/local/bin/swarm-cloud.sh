#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud

# Prefer a native binary if present
if [[ -x "./swarm-cloud-linux-amd64" ]]; then
  exec ./swarm-cloud-linux-amd64
fi

# Try known NodeJS entry points if Node is available
if command -v node >/dev/null 2>&1; then
  if [[ -f "./dist/apps/swarm-cloud-api/main.js" ]]; then
    exec node ./dist/apps/swarm-cloud-api/main.js
  fi
  if [[ -f "./dist/apps/swarm-node/main.js" ]]; then
    exec node ./dist/apps/swarm-node/main.js
  fi
fi

echo "swarm-cloud: no runnable entrypoint found (binary or NodeJS dist)" >&2
exit 1


