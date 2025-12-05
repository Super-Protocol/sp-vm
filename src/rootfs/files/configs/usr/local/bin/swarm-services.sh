#!/usr/bin/env bash
set -euo pipefail

dir="/sp/swarm/services"

if [ ! -d "$dir" ]; then
  exit 0
fi

# Wait for MySQL to become available (default: 127.0.0.1:3306, timeout 60s)
mysql_host="${DB_HOST:-127.0.0.1}"
mysql_port="${DB_PORT:-3306}"
wait_timeout="${DB_WAIT_TIMEOUT_SECONDS:-60}"
start_ts="$(date +%s)"
while true; do
  if (exec 3<>/dev/tcp/"$mysql_host"/"$mysql_port") 2>/dev/null; then
    exec 3>&- 3<&-
    break
  fi
  now_ts="$(date +%s)"
  elapsed=$(( now_ts - start_ts ))
  if [ "$elapsed" -ge "$wait_timeout" ]; then
    break
  fi
  sleep 1
done

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
