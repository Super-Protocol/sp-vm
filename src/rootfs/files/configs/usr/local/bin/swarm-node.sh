#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud
cp -fR /etc/swarm-cloud/services/ /var/lib/swarm-svc/
mkdir /var/lib/etc-wireguard
mkdir /var/lib/etc-rancher

exec node ./apps/swarm-node/dist/main.js
