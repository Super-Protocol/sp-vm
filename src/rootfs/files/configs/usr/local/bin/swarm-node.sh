#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud

exec node ./dist/apps/swarm-node/main.js
