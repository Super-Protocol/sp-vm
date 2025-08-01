#!/bin/bash

set -euo pipefail;

SUPER_REGISTRY_HOST="registry.superprotocol.local";
SUPER_CERTS_DIR="/opt/super/certs";
SUPER_CERT_FILEPATH="${SUPER_CERTS_DIR}/${SUPER_REGISTRY_HOST}";

pkill hauler || true;

sleep 3;  # enterprise delay

mkdir -p "/opt/hauler/.hauler";

find /etc/super/opt/hauler -type f -name "*.zst" | xargs /usr/local/bin/hauler store load --store /opt/hauler/store;

nohup /usr/local/bin/hauler store serve fileserver --store /opt/hauler/store --directory /opt/hauler/registry &

/usr/local/bin/hauler \
    store serve registry \
    --store /opt/hauler/store \
    --directory /opt/hauler/registry \
    --tls-cert="${SUPER_CERT_FILEPATH}.crt" \
    --tls-key="${SUPER_CERT_FILEPATH}.key";
