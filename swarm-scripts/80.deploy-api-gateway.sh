#!/bin/bash
set -euo pipefail

# Deploy and start api-gateway service
UNIT="sp-svc-api-gateway.service"

echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "Enabling and starting ${UNIT}..."
systemctl enable --now "${UNIT}"
systemctl is-active --quiet "${UNIT}" && echo "${UNIT} is active"
