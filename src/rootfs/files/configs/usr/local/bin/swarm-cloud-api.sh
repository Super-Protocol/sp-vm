#!/bin/bash

set -euo pipefail

cd /usr/local/lib/swarm-cloud

if [[ -x "./swarm-cloud-api-linux-amd64" ]]; then
  exec ./swarm-cloud-api-linux-amd64
fi

if command -v node >/dev/null 2>&1; then
  if [[ -f "./dist/apps/swarm-cloud-api/main.js" ]]; then
    exec node ./dist/apps/swarm-cloud-api/main.js
  fi
fi

echo "swarm-cloud-api: no runnable entrypoint found (binary or NodeJS dist)" >&2
exit 1
