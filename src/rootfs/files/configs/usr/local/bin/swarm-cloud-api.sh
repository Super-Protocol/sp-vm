#!/bin/bash

set -euo pipefail

cd /usr/local/lib/swarm-cloud

if command -v node >/dev/null 2>&1; then
  if [[ -f "./apps/swarm-cloud-api/dist/main.js" ]]; then
    exec node ./apps/swarm-cloud-api/dist/main.js
  fi
fi

echo "swarm-cloud-api: no runnable entrypoint found (binary or NodeJS dist)" >&2
exit 1
