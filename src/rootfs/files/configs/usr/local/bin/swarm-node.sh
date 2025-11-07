#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud
cp -fR /etc/swarm-cloud/services/ /var/lib/swarm-svc/
rmdir /etc/wireguard
mkdir /var/lib/etc-wireguard
ln -s /var/lib/etc-wireguard /etc/wireguard

exec node ./apps/swarm-node/dist/main.js
