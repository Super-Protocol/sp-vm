#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud

exec node ./apps/swarm-node/dist/main.js
