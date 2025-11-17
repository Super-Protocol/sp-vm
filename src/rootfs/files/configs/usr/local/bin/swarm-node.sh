#!/bin/bash

set -euo pipefail

mkdir -p /etc/wireguard

cd /etc/swarm-cloud

exec node ./apps/swarm-node/dist/main.js
