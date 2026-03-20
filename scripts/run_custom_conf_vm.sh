#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run Confidential VM in GCP.

Example:
  ./run_custom_conf_vm.sh \
    --raw ./disk.raw \
    --bucket gs://sp-bucket-conf-vms \
    --image sp-cloud-image \
    --vm sev-snp-guest-test \
    --zone us-central1-a \
    --machine-type n2d-standard-2 \
    --confidential-compute-type SEV_SNP \
    --data-disk data-disk \
    --data-disk-size 50GB \
    --data-disk-type pd-standard

Parameters:
    --raw <path> Path to raw disk (required)
    --bucket <bucket> GCS bucket (can be with gs://) (default: gs://sp-bucket-conf-vms)
    --image <name> GCE image name (default: sp-cloud-image, or \$IMAGE_NAME)
    --vm <name> VM name (default: sev-snp-guest-test, or \$INSTANCE_NAME)
    --zone <zone> Zone (default: us-central1-a)
    --machine-type <type> Machine type (default: n2d-standard-2)
    --confidential-compute-type <type> SEV_SNP | SEV | TDX (default: SEV_SNP; from CONFIDENTIAL_TYPE=SEVSNP)
    --guest-os-features <csv> Default: UEFI_COMPATIBLE,TDX_CAPABLE,SEV_CAPABLE,SEV_SNP_CAPABLE,GVNIC
    --data-disk <name> Data/state disk name (default: data-disk, or \$DISK_NAME)
    --data-disk-size <size> Disk size (default: 50GB, or \$DISK_SIZE)
    --data-disk-type <type> Disk type (default: pd-standard, or \$DISK_TYPE)
    --provider-config <path> Path to the provider_config folder (default: ./provider_config, or \$PROVIDER_CONFIG_DIR)
    --provider-bucket <name> GCS bucket name for provider_config (default: s3-provider-config, or \$PROVIDER_CONFIG_BUCKET)
    --skip-provider-config Skip downloading provider_config
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

DRY_RUN=0
RAW=""
BUCKET=""
IMAGE=""
VM=""
PROVIDER_CONFIG_DIR=""
PROVIDER_CONFIG_BUCKET=""
SKIP_PROVIDER_CONFIG=0
FORCE_OVERWRITE=0


while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW="${2:-}"; shift 2;;
    --bucket) BUCKET="${2:-}"; shift 2;;
    --image) IMAGE="${2:-}"; shift 2;;
    --vm) VM="${2:-}"; shift 2;;
    --zone) ZONE="${2:-}"; shift 2;;
    --machine-type) MACHINE_TYPE="${2:-}"; shift 2;;
    --confidential-compute-type) CONF_TYPE="${2:-}"; shift 2;;
    --guest-os-features) GUEST_OS_FEATURES="${2:-}"; shift 2;;
    --data-disk) DATA_DISK="${2:-}"; shift 2;;
    --data-disk-size) DATA_DISK_SIZE="${2:-}"; shift 2;;
    --data-disk-type) DATA_DISK_TYPE="${2:-}"; shift 2;;
    --provider-config) PROVIDER_CONFIG_DIR="${2:-}"; shift 2;;
    --provider-bucket) PROVIDER_CONFIG_BUCKET="${2:-}"; shift 2;;
    --skip-provider-config) SKIP_PROVIDER_CONFIG=1; shift 1;;
    --force-overwrite) FORCE_OVERWRITE=1; shift 1;;
    --dry-run) DRY_RUN=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)";;
  esac
done

# Default values (can be overridden via environment variables before running the script)
PROJECT_ID="${PROJECT_ID:-supa-swarm}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-n2d-standard-2}"

# Confidential type: read from CONFIDENTIAL_TYPE (SEVSNP/TDX/SEV) or explicit CLI flag
CONF_TYPE="${CONF_TYPE:-${CONFIDENTIAL_TYPE:-SEVSNP}}"
GUEST_OS_FEATURES="${GUEST_OS_FEATURES:-UEFI_COMPATIBLE,TDX_CAPABLE,SEV_CAPABLE,SEV_SNP_CAPABLE,GVNIC}"

# Data/state disk
DATA_DISK="$VM-data-disk"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-${DISK_SIZE:-50GB}}"
DATA_DISK_TYPE="${DATA_DISK_TYPE:-${DISK_TYPE:-pd-standard}}"

# Bucket for VM image tarball
BUCKET="${BUCKET:-gs://supa-swarm-bucket-conf-vms}"

# Provider config: local folder and bucket name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_CONFIG_DIR="${PROVIDER_CONFIG_DIR:-${SCRIPT_DIR}/provider_config}"
PROVIDER_CONFIG_BUCKET="${PROVIDER_CONFIG_BUCKET:-s3-provider-config}"

BUCKET="${BUCKET%/}"

[[ -n "$RAW" ]] || die "You must provide --raw"
[[ -f "$RAW" ]] || die "Raw file not found: $RAW"
[[ -n "$BUCKET" ]] || die "You must provide --bucket"

# Image: use CLI argument, or fallback to IMAGE_NAME or sp-cloud-image
if [[ -z "$IMAGE" ]]; then
  IMAGE="${IMAGE_NAME:-sp-cloud-image}"
fi
[[ -n "$IMAGE" ]] || die "You must provide --image or set IMAGE_NAME/sp-cloud-image"

if [[ -z "$VM" ]]; then
  VM="${INSTANCE_NAME:-sp-conf-vm}"
fi

need_cmd gcloud
need_cmd gsutil
need_cmd tar

# Use pigz for parallel compression if available, otherwise fallback to gzip
if command -v pigz > /dev/null 2>&1; then
  TAR_COMPRESS="pigz -p $(nproc)"
else
  echo "WARNING: pigz not found, falling back to single-threaded gzip. Install pigz for faster compression."
  TAR_COMPRESS="gzip"
fi

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

wait_for_instance_absent() {
  local instance_name="$1"
  local retries=60

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  while (( retries > 0 )); do
    if ! gcloud compute instances describe "${instance_name}" --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    retries=$((retries - 1))
  done

  die "Instance ${instance_name} is still present after waiting"
}

wait_for_disk_absent() {
  local disk_name="$1"
  local retries=60

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  while (( retries > 0 )); do
    if ! gcloud compute disks describe "${disk_name}" --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    retries=$((retries - 1))
  done

  die "Disk ${disk_name} is still present after waiting"
}

TAR_BASENAME="${IMAGE}.tar.gz"
IMAGE_TAR="${TAR_BASENAME}"
IMAGE_NAME="${IMAGE}"

# Normalize confidential VM type (default SEV-SNP)
case "${CONF_TYPE}" in
  SEVSNP|sev-snp|SEV-SNP|sev_snp|SEV_SNP|SevSnp|Sev-Snp) CONF_TYPE="SEV_SNP" ;;
  TDX|tdx|Tdx) CONF_TYPE="TDX" ;;
  SEV|sev|Sev) CONF_TYPE="SEV" ;;
esac

echo "Launch parameters:"
echo "  Project: ${PROJECT_ID}"
echo "  Bucket: ${BUCKET}/${IMAGE_TAR}"
echo "  Image: ${IMAGE_NAME}"
echo "  Zone: ${ZONE}"
echo "  Instance: ${VM}"
echo "  Disk: ${DATA_DISK} (${DATA_DISK_SIZE}, ${DATA_DISK_TYPE})"
echo "  Machine type: ${MACHINE_TYPE}"
echo "  Confidential type: ${CONF_TYPE}"
echo "  Raw disk: ${RAW}"
if [[ "$SKIP_PROVIDER_CONFIG" -eq 0 ]]; then
  echo "  Provider config: ${PROVIDER_CONFIG_DIR}"
  echo "  Provider bucket: ${PROVIDER_CONFIG_BUCKET}"
else
  echo "  Provider config: skipped (--skip-provider-config)"
fi
echo

mkdir -p ./tmpdir
TMPDIR="./tmpdir"
#cleanup() { rm -rf "$TMPDIR"; }
#trap cleanup EXIT

cp -f "$RAW" "${TMPDIR}/disk.raw"

echo "==> checking if image exists: ${IMAGE}"
IMAGE_EXISTS=0
if run gcloud compute images describe "${IMAGE}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  IMAGE_EXISTS=1
fi

if [[ "$IMAGE_EXISTS" -eq 1 ]] && [[ "$FORCE_OVERWRITE" -eq 0 ]]; then
  echo "==> Image ${IMAGE} already exists and --force-overwrite not specified. Skipping upload and creation."
else
  echo "==> pack raw disk into ${TAR_BASENAME} (compress via: ${TAR_COMPRESS})"
  (
    cd "$TMPDIR"
    run tar -S --use-compress-program="${TAR_COMPRESS}" -cf "${TAR_BASENAME}" disk.raw
  )

  echo "==> Uploading image tarball to GCS: ${BUCKET}/${TAR_BASENAME} (parallel composite upload)"
  run gsutil \
    -o "GSUtil:parallel_composite_upload_threshold=150MB" \
    -o "GSUtil:parallel_composite_upload_component_size=50MB" \
    -m cp "${TMPDIR}/${TAR_BASENAME}" "${BUCKET}/"

  if [[ "$IMAGE_EXISTS" -eq 1 ]]; then
      echo "==> Deleting image if it already exists: ${IMAGE} (project ${PROJECT_ID})"
      run gcloud compute images delete "${IMAGE}" \
          --project "${PROJECT_ID}" \
          --quiet || true
  fi

  echo "==> Creating image: ${IMAGE} in project ${PROJECT_ID}"
  run gcloud compute images create "${IMAGE}" \
    --project "${PROJECT_ID}" \
    --source-uri "${BUCKET}/${TAR_BASENAME}" \
    --guest-os-features="${GUEST_OS_FEATURES}"
fi

echo "==> checking if VM exists: ${VM}"
VM_EXISTS=0
if run gcloud compute instances describe "${VM}" --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
  VM_EXISTS=1
fi

if [[ "$VM_EXISTS" -eq 1 ]] && [[ "$FORCE_OVERWRITE" -eq 1 ]]; then
  echo "==> Deleting VM if it already exists: ${VM} (project ${PROJECT_ID}, zone ${ZONE})"
  run gcloud compute instances delete "${VM}" \
    --project "${PROJECT_ID}" \
    --zone "${ZONE}" \
    --delete-disks=all \
    --quiet || true
  echo "==> Waiting for VM deletion: ${VM}"
  wait_for_instance_absent "${VM}"
fi

echo "==> checking if disk exists: ${DATA_DISK}"
DISK_EXISTS=0
if run gcloud compute disks describe "${DATA_DISK}" --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
  DISK_EXISTS=1
fi

if [[ "$DISK_EXISTS" -eq 1 ]] && [[ "$FORCE_OVERWRITE" -eq 0 ]]; then
    echo "==> Disk ${DATA_DISK} already exists and --force-overwrite not specified. Skipping creation."
else
  if [[ "$DISK_EXISTS" -eq 1 ]]; then
      echo "==> Deleting data disk if it already exists: ${DATA_DISK} (project ${PROJECT_ID}, zone ${ZONE})"
      run gcloud compute disks delete "${DATA_DISK}" \
          --project "${PROJECT_ID}" \
          --zone "${ZONE}" \
          --quiet || true
      echo "==> Waiting for disk deletion: ${DATA_DISK}"
      wait_for_disk_absent "${DATA_DISK}"
  fi

  echo "==> Creating data disk: ${DATA_DISK} (${DATA_DISK_SIZE}, ${DATA_DISK_TYPE}) in project ${PROJECT_ID}"
  run gcloud compute disks create "${DATA_DISK}" \
    --project "${PROJECT_ID}" \
    --size "${DATA_DISK_SIZE}" \
    --type "${DATA_DISK_TYPE}" \
    --zone "${ZONE}"
fi

# Provider_config handling
PROVIDER_METADATA=""
if [[ "$SKIP_PROVIDER_CONFIG" -eq 0 ]] && [[ -d "$PROVIDER_CONFIG_DIR" ]]; then
  echo "==> Processing provider_config from ${PROVIDER_CONFIG_DIR}"
  
  # Ensure provider bucket exists (create if needed)
  PROVIDER_BUCKET_GS="gs://${PROVIDER_CONFIG_BUCKET}"
  if ! run gsutil ls "${PROVIDER_BUCKET_GS}" >/dev/null 2>&1; then
    echo "==> Creating bucket ${PROVIDER_CONFIG_BUCKET}"
    run gsutil mb -p "${PROJECT_ID}" "${PROVIDER_BUCKET_GS}" || true
  fi
  
  # Upload files from provider_config to bucket
  echo "==> Uploading files from ${PROVIDER_CONFIG_DIR} to ${PROVIDER_BUCKET_GS}"
  run gsutil -m cp -r "${PROVIDER_CONFIG_DIR}"/* "${PROVIDER_BUCKET_GS}/" || die "Failed to upload provider_config"
  
  # Create HMAC keys for S3-compatible access
  echo "==> Configuring S3-compatible access to GCS"
  
  # Ensure service account for S3 access exists
  SA_NAME="s3-access-sa"
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  
  if ! run gcloud iam service-accounts describe "${SA_EMAIL}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    echo "==> Create service account ${SA_NAME}"
    run gcloud iam service-accounts create "${SA_NAME}" \
      --project "${PROJECT_ID}" \
      --display-name "S3 Access Service Account" \
      --description "Service account for S3-compatible access to GCS" || true
  fi
  
  # Grant read-only access to service account (VM mounts via s3fs in read-only mode)
  run gsutil iam ch "serviceAccount:${SA_EMAIL}:roles/storage.objectViewer" "${PROVIDER_BUCKET_GS}" || true
  
  # Create HMAC key for S3-compatible access
  echo "==> Configuring HMAC keys for S3 access"
  
  # List existing keys
  EXISTING_KEYS=$(run gcloud storage hmac list "${SA_EMAIL}" --project "${PROJECT_ID}" --format="value(accessId)" 2>/dev/null || echo "")
  
  ACCESS_KEY=""
  SECRET_KEY=""
  
  if [[ -f "${SCRIPT_DIR}/.s3_credentials" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
    echo "==> Found existing local .s3_credentials file. Using it."
    source "${SCRIPT_DIR}/.s3_credentials"
  fi

  if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
    # List existing keys
    EXISTING_KEYS=$(run gcloud storage hmac list "${SA_EMAIL}" --project "${PROJECT_ID}" --format="value(accessId)" 2>/dev/null || echo "")
  
    # Delete old keys if any (secret is not retrievable after creation)
    if [[ -n "$EXISTING_KEYS" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
      echo "==> Deactivating and deleting old HMAC keys (limit reached if not deleted)"
      for KEY_ID in $EXISTING_KEYS; do
        run gcloud storage hmac update "${KEY_ID}" --state=INACTIVE --project "${PROJECT_ID}" 2>/dev/null || true
        run gcloud storage hmac delete "${KEY_ID}" --project "${PROJECT_ID}" 2>/dev/null || true
      done
    fi
  
    # Create a new HMAC key
    echo "==> Creating new HMAC key"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      HMAC_OUTPUT=$(run gcloud storage hmac create "${SA_EMAIL}" --project "${PROJECT_ID}" --format="json" 2>&1)
      ACCESS_KEY=$(echo "$HMAC_OUTPUT" | jq -r '.metadata.accessId' 2>/dev/null)
      SECRET_KEY=$(echo "$HMAC_OUTPUT" | jq -r '.secret' 2>/dev/null)
      
      if [[ "$SECRET_KEY" == "null" || -z "$SECRET_KEY" ]]; then
        # Check standard format as well just in case
        SECRET_KEY=$(echo "$HMAC_OUTPUT" | jq -r '.metadata.secret' 2>/dev/null)
      fi
    
      if [[ -n "$ACCESS_KEY" ]] && [[ -n "$SECRET_KEY" ]] && [[ "$ACCESS_KEY" != "null" ]] && [[ "$SECRET_KEY" != "null" ]]; then
        echo "==> HMAC key created successfully"
        echo "    Access Key: ${ACCESS_KEY}"
        echo "    Secret Key: ${SECRET_KEY:0:20}... (masked for safety)"
        
        # Save credentials locally to avoid creating new ones every run
        echo "ACCESS_KEY=\"${ACCESS_KEY}\"" > "${SCRIPT_DIR}/.s3_credentials"
        echo "SECRET_KEY=\"${SECRET_KEY}\"" >> "${SCRIPT_DIR}/.s3_credentials"
        chmod 600 "${SCRIPT_DIR}/.s3_credentials"
      else
        die "Failed to create HMAC key or parse response: $HMAC_OUTPUT"
      fi
    else
      ACCESS_KEY="<NEW_ACCESS_KEY>"
      SECRET_KEY="<NEW_SECRET_KEY>"
    fi
  fi
  
  # Pass S3-style credentials to VM via metadata
  if [[ -n "$ACCESS_KEY" ]] && [[ -n "$SECRET_KEY" ]]; then
    PROVIDER_METADATA="s3-access-key=${ACCESS_KEY},s3-secret-key=${SECRET_KEY},s3-bucket=${PROVIDER_CONFIG_BUCKET},s3-endpoint=https://storage.googleapis.com"
    echo "==> S3 credentials will be passed to the VM via metadata"
    echo "    Access Key: ${ACCESS_KEY}"
    echo "    Bucket: ${PROVIDER_CONFIG_BUCKET}"
    echo "    Endpoint: https://storage.googleapis.com"
  fi
  echo ""
elif [[ "$SKIP_PROVIDER_CONFIG" -eq 0 ]]; then
  echo "==> Skipping provider_config: directory ${PROVIDER_CONFIG_DIR} not found"
fi

echo "==> Create Confidential VM: ${VM} in ${PROJECT_ID}"
VM_CREATE_CMD=(
  gcloud compute instances create "${VM}"
  --project "${PROJECT_ID}"
  --zone "${ZONE}"
  --machine-type "${MACHINE_TYPE}"
  --maintenance-policy=TERMINATE
  --confidential-compute-type "${CONF_TYPE}"
  --enable-nested-virtualization
  --image "${IMAGE}"
  --tags=http-server,https-server,ssh-server,swarm
  --network-interface=nic-type=GVNIC
  --disk="name=${DATA_DISK},mode=rw"
)


if [[ -n "$PROVIDER_METADATA" ]]; then
  VM_CREATE_CMD+=(--metadata "${PROVIDER_METADATA}")
fi

run "${VM_CREATE_CMD[@]}"

echo "==> serial console"
run gcloud compute instances add-metadata "${VM}" \
  --project "${PROJECT_ID}" \
  --metadata serial-port-enable=TRUE \
  --zone "${ZONE}" >/dev/null 2>&1 || true

echo "==> Ensuring SSH firewall rule (port 22)"
if ! gcloud compute firewall-rules describe default-allow-ssh \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run gcloud compute firewall-rules create default-allow-ssh \
    --project "${PROJECT_ID}" \
    --allow tcp:22 \
    --target-tags ssh-server \
    --description "Allow inbound SSH on port 22" || true
fi

echo "==> serial port (port=1)"
run gcloud compute instances get-serial-port-output "${VM}" \
  --project "${PROJECT_ID}" \
  --port 1 --zone "${ZONE}" || true

cat <<EOF

  - serial console interactive:
      gcloud compute connect-to-serial-port "${VM}" --project "${PROJECT_ID}" --port 1 --zone "${ZONE}"
  - ssh (username):
      gcloud compute ssh root@"${VM}" --project "${PROJECT_ID}" --zone "${ZONE}"
EOF

if [[ -n "$PROVIDER_METADATA" ]]; then
  cat <<EOF

mounting provider_config via s3fs in a VM:

Inside the VM, get credentials from metadata:

    ACCESS_KEY=\$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-access-key" -H "Metadata-Flavor: Google")
    SECRET_KEY=\$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-secret-key" -H "Metadata-Flavor: Google")
    BUCKET=\$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-bucket" -H "Metadata-Flavor: Google")
    ENDPOINT=\$(curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/s3-endpoint" -H "Metadata-Flavor: Google")

Create a file with credentials for s3fs:
    echo "\${ACCESS_KEY}:\${SECRET_KEY}" > /etc/passwd-s3fs
    chmod 600 /etc/passwd-s3fs

Create a mount point and mount:
    mkdir -p /sp/
    s3fs \${BUCKET} /sp/ \\
      -o url=\${ENDPOINT} \\
      -o passwd_file=/etc/passwd-s3fs \\
      -o use_path_request_style

Check metadata inside VM:
    curl -s "http://169.254.169.254/computeMetadata/v1/instance/attributes/?recursive=true" -H "Metadata-Flavor: Google" | jq .

Alias for metadata:
    echo "169.254.169.254 metadata.google.internal metadata" | tee -a /etc/hosts
EOF
fi


