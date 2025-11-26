#!/bin/bash

set -euo pipefail

if [[ ! -x /usr/local/bin/kubectl ]]; then
  echo "kubectl binary not found at /usr/local/bin/kubectl" >&2
  exit 0
fi

mkdir -p /var/lib/rancher/rke2/bin

if [[ ! -e /var/lib/rancher/rke2/bin/kubectl ]]; then
  ln -s /usr/local/bin/kubectl /var/lib/rancher/rke2/bin/kubectl || true
fi

exit 0
