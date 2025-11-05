#!/bin/bash

set -euo pipefail

for d in \
  /run/state/var \
  /run/state/kubernetes \
  /run/state/opt \
  /run/state/etciscsi
do
  mkdir -p "$d"
done
