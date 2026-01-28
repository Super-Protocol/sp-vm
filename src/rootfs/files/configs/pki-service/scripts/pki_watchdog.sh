#!/bin/bash

SERVICE="pki-authority.service"
MIN_UPTIME_SECONDS=180  # 3 minutes

# Check if service is enabled
if ! systemctl is-enabled --quiet "$SERVICE"; then
    exit 0
fi

# Check if service is active
if ! systemctl is-active --quiet "$SERVICE"; then
    exit 0
fi

# Get service activation time (unix timestamp)
ACTIVE_ENTER=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE")
if [ -z "$ACTIVE_ENTER" ] || [ "$ACTIVE_ENTER" = "n/a" ]; then
    exit 0
fi

# Convert to unix timestamp
ACTIVE_ENTER_SEC=$(date -d "$ACTIVE_ENTER" +%s 2>/dev/null)
if [ -z "$ACTIVE_ENTER_SEC" ]; then
    exit 0
fi

# Get current time
CURRENT_SEC=$(date +%s)

# Calculate uptime in seconds
UPTIME_SEC=$((CURRENT_SEC - ACTIVE_ENTER_SEC))

# If uptime is less than 3 minutes - exit
if [ "$UPTIME_SEC" -lt "$MIN_UPTIME_SECONDS" ]; then
    exit 0
fi

# Run healthcheck
/usr/bin/python3 /usr/local/bin/pki-authority/pki_healthcheck.py || {
    /usr/bin/systemctl restart "$SERVICE"
}
