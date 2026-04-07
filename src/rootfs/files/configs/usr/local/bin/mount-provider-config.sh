#!/bin/bash
set -euo pipefail

log() { echo "[mount-provider-config] $*"; }
log_err() { echo "[mount-provider-config] ERROR: $*" >&2; }

if [[ -d /sp ]] && [[ -n "$(ls -A /sp 2>/dev/null)" ]]; then
    log "/sp already exists and is not empty, skipping mount provider config"
    exit 0
fi

METADATA_URL="http://169.254.169.254/computeMetadata/v1/instance/attributes"
META_HEADER="Metadata-Flavor: Google"
PASSWD_FILE="/etc/passwd-s3fs"

ACCESS_KEY="$(curl -sf "${METADATA_URL}/s3-access-key" -H "${META_HEADER}" || true)"
SECRET_KEY="$(curl -sf "${METADATA_URL}/s3-secret-key" -H "${META_HEADER}" || true)"
BUCKET="$(curl -sf    "${METADATA_URL}/s3-bucket"     -H "${META_HEADER}" || true)"
ENDPOINT="$(curl -sf  "${METADATA_URL}/s3-endpoint"   -H "${META_HEADER}" || true)"
ENDPOINT="${ENDPOINT:-https://storage.googleapis.com}"
S3_PATH="$(curl -sf   "${METADATA_URL}/s3-path"       -H "${META_HEADER}" || true)"

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || -z "$BUCKET" ]]; then
    log "S3 credentials not found in GCP metadata — /sp will remain empty."
    exit 0
fi

mkdir -p /sp

# Write s3fs credentials file
printf '%s:%s\n' "${ACCESS_KEY}" "${SECRET_KEY}" > "${PASSWD_FILE}"
chmod 600 "${PASSWD_FILE}"

log "Mounting gs://${BUCKET}${S3_PATH} → /sp (endpoint: ${ENDPOINT})"

# s3fs syntax for subdirectory: "BUCKET:/prefix" mounts only that prefix
if [[ -n "${S3_PATH}" ]]; then
    S3FS_BUCKET="${BUCKET}:${S3_PATH}"
else
    S3FS_BUCKET="${BUCKET}"
fi

s3fs "${S3FS_BUCKET}" /sp \
    -o url="${ENDPOINT}" \
    -o passwd_file="${PASSWD_FILE}" \
    -o use_path_request_style \
    -o compat_dir \
    -o ro \
    -o allow_other \
    -o nonempty \
    -o retries=5 \
    -o connect_timeout=30 \
    -o uid=0 \
    -o gid=0 \
    -o umask=0022 \
    -o logfile=/var/log/s3fs-provider-config.log

log "Mounted OK. Contents: $(ls /sp/ 2>/dev/null | head -10 | tr '\n' ' ')"
