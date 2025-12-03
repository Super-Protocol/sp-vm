#!/bin/bash
set -euo pipefail

# Deploy and start content-certificates-service
UNIT="sp-svc-content-certificates-service.service"

echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "Enabling and starting ${UNIT}..."
systemctl enable --now "${UNIT}"
systemctl is-active --quiet "${UNIT}" && echo "${UNIT} is active"
