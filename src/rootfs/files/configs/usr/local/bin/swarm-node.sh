#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud

if [[ -x "./swarm-node-linux-amd64" ]]; then
  exec ./swarm-node-linux-amd64
fi

if command -v node >/dev/null 2>&1; then
  if [[ -f "./dist/apps/swarm-node/main.js" ]]; then
    exec node ./dist/apps/swarm-node/main.js
  fi
fi

echo "swarm-node: no runnable entrypoint found (binary or NodeJS dist)" >&2
exit 1


