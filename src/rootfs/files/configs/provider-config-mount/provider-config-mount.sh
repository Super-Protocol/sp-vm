#!/usr/bin/env bash
set -euo pipefail

SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo '')"
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo '')"
PRODUCT_NAME="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo '')"

IS_GCP=false
if [[ "$SYS_VENDOR" == "Google" ]] || \
   [[ "$SYS_VENDOR" == "Google Compute Engine" ]] || \
   [[ "$VIRT_TYPE" == "google" ]] || \
   [[ "$PRODUCT_NAME" == "Google Compute Engine" ]]; then
    IS_GCP=true
fi

# Fallback: try to reach the GCP metadata endpoint
if [[ "$IS_GCP" == "false" ]]; then
    if curl -s --connect-timeout 2 -H "Metadata-Flavor: Google" \
            "http://169.254.169.254/computeMetadata/v1/instance/id" &>/dev/null; then
        IS_GCP=true
    fi
fi

if [[ "$IS_GCP" == "false" ]]; then
    echo "Not running in GCP. Skipping provider-config-mount."
    exit 0
fi

echo "Running in GCP. Fetching S3 credentials from metadata..."

ACCESS_KEY=$(curl -sf --connect-timeout 5 "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-access-key" -H "Metadata-Flavor: Google" || echo "")
SECRET_KEY=$(curl -sf --connect-timeout 5 "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-secret-key" -H "Metadata-Flavor: Google" || echo "")
BUCKET=$(curl -sf --connect-timeout 5 "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-bucket" -H "Metadata-Flavor: Google" || echo "")
ENDPOINT=$(curl -sf --connect-timeout 5 "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-endpoint" -H "Metadata-Flavor: Google" || echo "")

echo "  ACCESS_KEY present: $([[ -n "$ACCESS_KEY" ]] && echo yes || echo NO)"
echo "  SECRET_KEY present: $([[ -n "$SECRET_KEY" ]] && echo yes || echo NO)"
echo "  BUCKET: ${BUCKET:-<empty>}"
echo "  ENDPOINT: ${ENDPOINT:-<empty>}"

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$BUCKET" ] || [ -z "$ENDPOINT" ]; then
    echo "S3 metadata attributes are missing. Not mounting /sp/"
    exit 0
fi

if ! grep -q "metadata.google.internal" /etc/hosts; then
    echo "169.254.169.254 metadata.google.internal metadata" >> /etc/hosts
fi

echo "${ACCESS_KEY}:${SECRET_KEY}" > /etc/passwd-s3fs
chmod 600 /etc/passwd-s3fs

mkdir -p /sp/

if mountpoint -q /sp/; then
    echo "/sp/ already mounted, unmounting first..."
    umount /sp/ || true
fi

echo "Mounting s3fs: bucket=${BUCKET} endpoint=${ENDPOINT}"
s3fs "${BUCKET}" /sp/ \
    -o url="${ENDPOINT}" \
    -o passwd_file=/etc/passwd-s3fs \
    -o use_path_request_style \
    -o allow_other
echo "s3fs mounted successfully."
