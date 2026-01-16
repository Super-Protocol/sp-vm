#!/bin/bash

set -euo pipefail

cd /usr/local/lib/swarm-cloud

exec node ./apps/swarm-node/dist/main.js
