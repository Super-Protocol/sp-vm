#!/bin/bash
set -euo pipefail

METADATA_URL="http://169.254.169.254/computeMetadata/v1/instance/attributes"
META_HEADER="Metadata-Flavor: Google"
PASSWD_FILE="/etc/passwd-s3fs"

log() { echo "[mount-provider-config] $*"; }
log_err() { echo "[mount-provider-config] ERROR: $*" >&2; }

ACCESS_KEY="$(curl -sf "${METADATA_URL}/s3-access-key" -H "${META_HEADER}" || true)"
SECRET_KEY="$(curl -sf "${METADATA_URL}/s3-secret-key" -H "${META_HEADER}" || true)"
BUCKET="$(curl -sf    "${METADATA_URL}/s3-bucket"     -H "${META_HEADER}" || true)"
ENDPOINT="$(curl -sf  "${METADATA_URL}/s3-endpoint"   -H "${META_HEADER}" || true)"
ENDPOINT="${ENDPOINT:-https://storage.googleapis.com}"

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || -z "$BUCKET" ]]; then
    log "S3 credentials not found in GCP metadata — /sp will remain empty."
    exit 0
fi

mkdir -p /sp

# Write s3fs credentials file
printf '%s:%s\n' "${ACCESS_KEY}" "${SECRET_KEY}" > "${PASSWD_FILE}"
chmod 600 "${PASSWD_FILE}"

log "Mounting gs://${BUCKET} → /sp (endpoint: ${ENDPOINT})"
s3fs "${BUCKET}" /sp \
    -o url="${ENDPOINT}" \
    -o passwd_file="${PASSWD_FILE}" \
    -o use_path_request_style \
    -o ro \
    -o allow_other \
    -o nonempty \
    -o retries=5 \
    -o connect_timeout=30 \
    -o logfile=/var/log/s3fs-provider-config.log

log "Mounted OK. Contents: $(ls /sp/ 2>/dev/null | head -10 | tr '\n' ' ')"
