#!/bin/bash

set -euo pipefail

# Ensure required subdirectories exist on the mounted state filesystem
for d in \
  /run/state/var \
  /run/state/kubernetes \
  /run/state/opt \
  /run/state/etciscsi
do
  mkdir -p "$d"
done
