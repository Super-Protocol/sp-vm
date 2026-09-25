#!/bin/bash
set -euo pipefail

# Populates /sp with the operator-supplied provider_config.
#
# Three delivery paths exist:
#   - on-premise: the initramfs already mounted a disk labelled provider_config
#     at /sp, so there is nothing to do here;
#   - GCP: credentials arrive as instance metadata and /sp is a live s3fs mount;
#   - Azure: userData carries a blob URL, the archive is downloaded once and
#     unpacked into /sp (which lives on the encrypted state disk).

log() { echo "[provider-config] $*"; }
log_err() { echo "[provider-config] ERROR: $*" >&2; }

SP_DIR="/sp"
PASSWD_FILE="/etc/passwd-s3fs"

IMDS_HOST="169.254.169.254"
AZURE_IMDS_COMPUTE="http://${IMDS_HOST}/metadata/instance/compute"
AZURE_CHASSIS_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"
GCP_METADATA_URL="http://${IMDS_HOST}/computeMetadata/v1/instance/attributes"
GCP_META_HEADER="Metadata-Flavor: Google"

STAGE_DIR=""
cleanup() {
    if [[ -n "$STAGE_DIR" ]] && [[ -d "$STAGE_DIR" ]]; then
        rm -rf "$STAGE_DIR"
    fi
}
trap cleanup EXIT

dmi_value() {
    local path="/sys/class/dmi/id/$1"
    if [[ -r "$path" ]]; then
        tr -d '\0' <"$path" 2>/dev/null || true
    fi
}

# Both clouds answer on 169.254.169.254, so identify the platform offline via
# DMI first and never send one cloud's metadata header to the other. Keeping the
# happy path down to a single IMDS request also matters because
# pki_configure_helper.py detects "Azure confidential VM" with a 0.5s IMDS
# timeout and silently treats any failure as "not a CVM".
detect_cloud() {
    if [[ "$(dmi_value chassis_asset_tag)" == "$AZURE_CHASSIS_ASSET_TAG" ]]; then
        echo "azure"
        return 0
    fi
    if [[ "$(dmi_value sys_vendor)" == *Google* ]]; then
        echo "gcp"
        return 0
    fi

    log "DMI did not identify the platform, probing metadata services" >&2
    if curl -sf --max-time 3 -H 'Metadata: true' \
        "${AZURE_IMDS_COMPUTE}/azEnvironment?api-version=2021-02-01&format=text" \
        >/dev/null 2>&1; then
        echo "azure"
        return 0
    fi
    if curl -sf --max-time 3 -H "$GCP_META_HEADER" \
        "http://${IMDS_HOST}/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
        echo "gcp"
        return 0
    fi
    return 0
}

do_azure() {
    local user_data descriptor url sha256

    user_data="$(curl -sf --max-time 10 -H 'Metadata: true' \
        "${AZURE_IMDS_COMPUTE}/userData?api-version=2021-01-01&format=text" || true)"
    if [[ -z "$user_data" ]]; then
        log_err "Azure userData is empty — no provider_config was supplied when the VM was created."
        log_err "Recreate the VM with scripts/azure/run_custom_conf_vm.sh."
        exit 1
    fi

    descriptor="$(printf '%s' "$user_data" | base64 -d 2>/dev/null || true)"
    url="$(printf '%s' "$descriptor" | jq -r '.provider_config.url // empty' 2>/dev/null || true)"
    sha256="$(printf '%s' "$descriptor" | jq -r '.provider_config.sha256 // empty' 2>/dev/null || true)"
    if [[ -z "$url" ]] || [[ -z "$sha256" ]]; then
        log_err "Azure userData does not carry a provider_config descriptor (expected .provider_config.url and .sha256)."
        exit 1
    fi

    # /run is tmpfs, so the payload never touches unencrypted storage; /sp is on
    # the LUKS-encrypted state disk.
    umask 077
    STAGE_DIR="$(mktemp -d /run/provider-config.XXXXXX)"

    log "Downloading provider_config archive"
    if ! curl -sSfL --max-time 300 --retry 3 --retry-delay 5 \
        -o "${STAGE_DIR}/payload.tar.gz" "$url"; then
        log_err "Failed to download the provider_config archive."
        log_err "It may have been removed by the storage lifecycle policy; re-run scripts/azure/run_custom_conf_vm.sh."
        exit 1
    fi

    if ! printf '%s  %s\n' "$sha256" "${STAGE_DIR}/payload.tar.gz" \
        | sha256sum --check --strict --status; then
        log_err "provider_config archive failed the sha256 check — refusing to unpack it."
        exit 1
    fi

    # Unpack to a staging directory and only then populate /sp: a non-empty /sp
    # is the idempotence guard, so a half-extracted /sp would permanently
    # short-circuit every retry.
    mkdir -p "${STAGE_DIR}/unpacked"
    tar -xzf "${STAGE_DIR}/payload.tar.gz" -C "${STAGE_DIR}/unpacked" --no-same-owner

    mkdir -p "$SP_DIR"
    cp -a "${STAGE_DIR}/unpacked/." "${SP_DIR}/"
    chown -R root:root "$SP_DIR"
    find "$SP_DIR" -type d -exec chmod 0755 {} +
    find "$SP_DIR" -type f -exec chmod 0644 {} +
    if [[ -f "${SP_DIR}/authorized_keys" ]]; then
        # sshd reads /sp/authorized_keys and enforces StrictModes.
        chmod 0400 "${SP_DIR}/authorized_keys"
    fi

    log "Provider config ready. Contents: $(ls "$SP_DIR" 2>/dev/null | head -10 | tr '\n' ' ')"
}

do_gcp() {
    local ACCESS_KEY SECRET_KEY BUCKET ENDPOINT S3_PATH S3FS_BUCKET

    ACCESS_KEY="$(curl -sf "${GCP_METADATA_URL}/s3-access-key" -H "${GCP_META_HEADER}" || true)"
    SECRET_KEY="$(curl -sf "${GCP_METADATA_URL}/s3-secret-key" -H "${GCP_META_HEADER}" || true)"
    BUCKET="$(curl -sf    "${GCP_METADATA_URL}/s3-bucket"     -H "${GCP_META_HEADER}" || true)"
    ENDPOINT="$(curl -sf  "${GCP_METADATA_URL}/s3-endpoint"   -H "${GCP_META_HEADER}" || true)"
    ENDPOINT="${ENDPOINT:-https://storage.googleapis.com}"
    S3_PATH="$(curl -sf   "${GCP_METADATA_URL}/s3-path"       -H "${GCP_META_HEADER}" || true)"

    if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || -z "$BUCKET" ]]; then
        log "S3 credentials not found in GCP metadata — /sp will remain empty."
        exit 1
    fi

    mkdir -p "$SP_DIR"

    # Write s3fs credentials file
    printf '%s:%s\n' "${ACCESS_KEY}" "${SECRET_KEY}" > "${PASSWD_FILE}"
    chmod 600 "${PASSWD_FILE}"

    log "Mounting gs://${BUCKET}${S3_PATH} → ${SP_DIR} (endpoint: ${ENDPOINT})"

    # s3fs syntax for subdirectory: "BUCKET:/prefix" mounts only that prefix
    if [[ -n "${S3_PATH}" ]]; then
        S3FS_BUCKET="${BUCKET}:${S3_PATH}"
    else
        S3FS_BUCKET="${BUCKET}"
    fi

    s3fs "${S3FS_BUCKET}" "$SP_DIR" \
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

    log "Mounted OK. Contents: $(ls "$SP_DIR" 2>/dev/null | head -10 | tr '\n' ' ')"
}

do_start() {
    local cloud

    if [[ -d "$SP_DIR" ]] && [[ -n "$(ls -A "$SP_DIR" 2>/dev/null)" ]]; then
        log "${SP_DIR} already exists and is not empty, nothing to do"
        exit 0
    fi

    cloud="$(detect_cloud)"
    case "$cloud" in
        azure) log "Detected Azure"; do_azure ;;
        gcp)   log "Detected GCP";   do_gcp ;;
        *)
            log_err "No provider_config disk and no supported metadata service — ${SP_DIR} will remain empty."
            exit 1
            ;;
    esac
}

# Only the GCP path leaves a FUSE mount behind; on the other paths /sp holds
# plain files that must survive a restart of the units that Requires= this one.
do_stop() {
    if mountpoint -q "$SP_DIR" 2>/dev/null; then
        fusermount -uz "$SP_DIR" || true
    fi
    exit 0
}

case "${1:-start}" in
    start) do_start ;;
    stop)  do_stop ;;
    *)
        log_err "Usage: $0 [start|stop]"
        exit 2
        ;;
esac
