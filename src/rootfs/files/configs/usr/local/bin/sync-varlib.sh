#!/bin/bash

set -euo pipefail

src_root="/etc/super/var/lib"
dst_root="/var/lib"

if [[ ! -d "$src_root" ]]; then
  exit 0
fi

mkdir -p "$dst_root"
cp -a "$src_root/." "$dst_root/"
