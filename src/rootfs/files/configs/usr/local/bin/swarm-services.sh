#!/usr/bin/env bash
set -euo pipefail

dir="/sp/swarm/services"

if [ ! -d "$dir" ]; then
  exit 0
fi

shopt -s nullglob
scripts=("$dir"/*.sh)
if [ ${#scripts[@]} -eq 0 ]; then
  exit 0
fi

IFS=$'\n' sorted=($(printf "%s\n" "${scripts[@]}" | sort))
unset IFS

for script in "${sorted[@]}"; do
  if [ -f "$script" ]; then
    if [ -x "$script" ]; then
      "$script"
    else
      bash "$script"
    fi
  fi
done
