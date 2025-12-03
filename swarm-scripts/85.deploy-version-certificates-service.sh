#!/bin/bash
set -euo pipefail

# Deploy and start version-certificates-service
UNIT="sp-svc-version-certificates-service.service"

echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "Enabling and starting ${UNIT}..."
systemctl enable --now "${UNIT}"
systemctl is-active --quiet "${UNIT}" && echo "${UNIT} is active"
