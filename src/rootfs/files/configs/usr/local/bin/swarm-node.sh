#!/bin/bash

set -euo pipefail

cd /etc/swarm-cloud
cp -fR /etc/swarm-cloud/services/ /var/lib/swarm-svc/

exec node ./apps/swarm-node/dist/main.js
