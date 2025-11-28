#!/bin/bash

set -euo pipefail

UI_DIR="/usr/local/lib/swarm-cloud/dist/apps/swarm-cloud-ui"

if [[ -d "${UI_DIR}/out" && -f "${UI_DIR}/out/index.html" ]]; then
  cd "${UI_DIR}/out"
  exec python3 -m http.server 32198 --bind 0.0.0.0
elif [[ -d "${UI_DIR}/.next" ]]; then
  cd "${UI_DIR}"
  if [[ -x "./node_modules/.bin/next" ]]; then
    exec ./node_modules/.bin/next start -p 32198
  fi
fi

echo "swarm-cloud-ui: no runnable artifacts found (expected 'out' or '.next' with next runtime)" >&2
exit 1
