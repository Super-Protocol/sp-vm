#!/bin/bash

set -euo pipefail

cd /usr/local/lib/swarm-cloud

exec node ./dist/apps/swarm-node/main.js
