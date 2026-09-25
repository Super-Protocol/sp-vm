#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Upload a raw disk image to GCS and create a GCE image.

Example:
  ./upload_custom_conf_image.sh \
    --raw ./out/sp-vm-build-1.img \
    --image sp-cloud-image-vlad \
    --force-overwrite-image

Parameters:
  --raw <path> Path to raw disk image (required)
  --bucket <bucket> GCS bucket (can be with gs://) (default: gs://supa-swarm-bucket-conf-vms)
  --image <name> GCE image name (default: sp-cloud-image, or $IMAGE_NAME)
  --guest-os-features <csv> Default: UEFI_COMPATIBLE,TDX_CAPABLE,SEV_CAPABLE,SEV_SNP_CAPABLE,GVNIC
  --force-overwrite-image Recreate image if it already exists
  --dry-run Print commands without executing them
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
GUEST_OS_FEATURES=""
FORCE_OVERWRITE_IMAGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW="${2:-}"; shift 2 ;;
    --bucket) BUCKET="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --guest-os-features) GUEST_OS_FEATURES="${2:-}"; shift 2 ;;
    --force-overwrite-image) FORCE_OVERWRITE_IMAGE=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

PROJECT_ID="${PROJECT_ID:-supa-swarm}"
BUCKET="${BUCKET:-gs://supa-swarm-bucket-conf-vms}"
BUCKET="${BUCKET%/}"
GUEST_OS_FEATURES="${GUEST_OS_FEATURES:-UEFI_COMPATIBLE,TDX_CAPABLE,SEV_CAPABLE,SEV_SNP_CAPABLE,GVNIC}"

if [[ -z "$IMAGE" ]]; then
  IMAGE="${IMAGE_NAME:-sp-cloud-image}"
fi

[[ -n "$RAW" ]] || die "You must provide --raw"
[[ -f "$RAW" ]] || die "Raw file not found: $RAW"
[[ -n "$BUCKET" ]] || die "You must provide --bucket"
[[ -n "$IMAGE" ]] || die "You must provide --image or set IMAGE_NAME"

need_cmd gcloud
need_cmd gsutil
need_cmd tar

if command -v pigz >/dev/null 2>&1; then
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

IMAGE_NAME="${IMAGE}"
TAR_BASENAME="${IMAGE}.tar.gz"
TMPDIR="$(mktemp -d ./tmpdir.image.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Upload parameters:"
echo "  Project: ${PROJECT_ID}"
echo "  Raw disk: ${RAW}"
echo "  Bucket: ${BUCKET}/${TAR_BASENAME}"
echo "  Image: ${IMAGE_NAME}"
echo

echo "==> checking if image exists: ${IMAGE_NAME}"
IMAGE_EXISTS=0
if run gcloud compute images describe "${IMAGE_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  IMAGE_EXISTS=1
fi

if [[ "$IMAGE_EXISTS" -eq 1 ]] && [[ "$FORCE_OVERWRITE_IMAGE" -eq 0 ]]; then
  die "Image ${IMAGE_NAME} already exists. Re-run with --force-overwrite-image to replace it."
fi

cp -f "$RAW" "${TMPDIR}/disk.raw"

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
  echo "==> Deleting image if it already exists: ${IMAGE_NAME} (project ${PROJECT_ID})"
  run gcloud compute images delete "${IMAGE_NAME}" \
    --project "${PROJECT_ID}" \
    --quiet
fi

echo "==> Creating image: ${IMAGE_NAME} in project ${PROJECT_ID}"
run gcloud compute images create "${IMAGE_NAME}" \
  --project "${PROJECT_ID}" \
  --source-uri "${BUCKET}/${TAR_BASENAME}" \
  --guest-os-features="${GUEST_OS_FEATURES}"

echo
echo "==> Image upload completed"
echo "  gcloud compute images describe \"${IMAGE_NAME}\" --project \"${PROJECT_ID}\""
