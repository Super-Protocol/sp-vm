#!/bin/bash

set -euo pipefail

mkdir -p /var/lib/rancher/rke2/bin

# If RKE2 kubectl exists, ensure /usr/local/bin/kubectl points to it
if [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
  exit 0
fi

# Otherwise, do nothing; symlink will become valid once RKE2 installs kubectl
exit 0
