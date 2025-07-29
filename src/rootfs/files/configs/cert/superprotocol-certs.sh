#!/bin/bash

set -euo pipefail;

SUPER_REGISTRY_HOST="registry.superprotocol.local";
SUPER_CERT_INITIAL_DIR="/etc/super/certs";
SUPER_CERTS_DIR="/opt/super/certs";
SUPER_CERT_FILEPATH="$SUPER_CERTS_DIR/$SUPER_REGISTRY_HOST";

mkdir -p "$SUPER_CERTS_DIR";
cp $SUPER_CERT_INITIAL_DIR/* $SUPER_CERTS_DIR/

/var/lib/rancher/rke2/bin/kubectl \
    create secret tls docker-registry-tls \
    --namespace super-protocol \
    "--cert=$SUPER_CERT_FILEPATH.crt" \
    "--key=$SUPER_CERT_FILEPATH.key" \
    --dry-run=client \
    --output=yaml > /var/lib/rancher/rke2/server/manifests/docker-registry-tls.yaml;
