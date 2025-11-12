#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud
cp -fR /etc/swarm-cloud/services/ /var/lib/swarm-svc/
mkdir /var/lib/etc-wireguard
mkdir -p /var/lib/etc-rancher/rke2

exec node ./apps/swarm-node/dist/main.js
