#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Upload a raw sp-vm disk image to Azure Compute Gallery as an image version
that can boot both Confidential (TDX / SEV-SNP) and regular VMs.

The raw image is converted to a fixed VHD, uploaded as a page blob to a
staging storage account, and imported into the gallery. Azure accepts only
VHD blobs as a source for Confidential VM capable images.

Examples:
  ./upload_gallery_image.sh --raw ./out/sp-vm-build-435-debug.img

  ./upload_gallery_image.sh \
    --acr-image superprotocol.azurecr.io/sp-vm:build-435-debug \
    --force-overwrite-image

Parameters:
  --raw <path> Path to raw disk image (sp-vm-build-<N>-<type>.img)
  --acr-image <ref> Pull the raw image from an ACR OCI image instead of --raw
  --build-tag <tag> build-<N>-<debug|release> (default: taken from the file or image name)
  --resource-group <name> Default: sp-vm-images (or $AZURE_RESOURCE_GROUP)
  --location <region> Default: westus3 (or $AZURE_LOCATION)
  --gallery <name> Default: sp_vm_images (or $AZURE_GALLERY)
  --storage-account <name> Staging account for VHD blobs
                           (default: spvmimg<hash of subscription id>, or $AZURE_STORAGE_ACCOUNT)
  --target-regions <list> Space separated replication regions (default: --location)
  --security-type <type> Image definition security type
                         (default: TrustedLaunchAndConfidentialVmSupported)
  --work-dir <path> Where the temporary VHD is written (default: current directory)
  --keep-vhd Keep the staging VHD blob after the image version is created
  --force-overwrite-image Recreate the image version if it already exists
  --dry-run Print commands without executing them

The gallery image version is <N>.0.0 of image definition sp-vm-<type>.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

DRY_RUN=0
RAW=""
ACR_IMAGE=""
BUILD_TAG=""
TARGET_REGIONS=""
STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
WORK_DIR="."
KEEP_VHD=0
FORCE_OVERWRITE_IMAGE=0
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-sp-vm-images}"
LOCATION="${AZURE_LOCATION:-westus3}"
GALLERY="${AZURE_GALLERY:-sp_vm_images}"
SECURITY_TYPE="TrustedLaunchAndConfidentialVmSupported"
CONTAINER="vhds"
MIB=1048576

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW="${2:-}"; shift 2 ;;
    --acr-image) ACR_IMAGE="${2:-}"; shift 2 ;;
    --build-tag) BUILD_TAG="${2:-}"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --gallery) GALLERY="${2:-}"; shift 2 ;;
    --storage-account) STORAGE_ACCOUNT="${2:-}"; shift 2 ;;
    --target-regions) TARGET_REGIONS="${2:-}"; shift 2 ;;
    --security-type) SECURITY_TYPE="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --keep-vhd) KEEP_VHD=1; shift 1 ;;
    --force-overwrite-image) FORCE_OVERWRITE_IMAGE=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

[[ -n "$RAW" || -n "$ACR_IMAGE" ]] || die "You must provide --raw or --acr-image"
[[ -z "$RAW" || -z "$ACR_IMAGE" ]] || die "--raw and --acr-image are mutually exclusive"
[[ -z "$RAW" || -f "$RAW" ]] || die "Raw file not found: $RAW"
[[ -d "$WORK_DIR" ]] || die "Work directory not found: $WORK_DIR"

if [[ -z "$BUILD_TAG" ]]; then
  if [[ -n "$RAW" ]]; then
    BUILD_TAG="$(basename "$RAW" .img)"
    BUILD_TAG="${BUILD_TAG#sp-vm-}"
  else
    BUILD_TAG="${ACR_IMAGE##*:}"
  fi
fi

[[ "$BUILD_TAG" =~ ^build-([0-9]+)-(debug|release)$ ]] \
  || die "Cannot derive build tag (expected build-<N>-<debug|release>, got '${BUILD_TAG}'); pass --build-tag"
IMAGE_DEFINITION="sp-vm-${BASH_REMATCH[2]}"
IMAGE_VERSION="${BASH_REMATCH[1]}.0.0"
TARGET_REGIONS="${TARGET_REGIONS:-$LOCATION}"
BLOB_NAME="${BUILD_TAG}.vhd"
COMMIT="${GITHUB_SHA:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || echo unknown)}"

need_cmd az
need_cmd sha256sum
[[ -z "$ACR_IMAGE" ]] || need_cmd docker

az account show >/dev/null 2>&1 || die "Not logged in to Azure (run: az login)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

if [[ -z "$STORAGE_ACCOUNT" ]]; then
  STORAGE_ACCOUNT="spvmimg$(printf '%s' "$SUBSCRIPTION_ID" | sha256sum | cut -c1-10)"
fi

TMPDIR="$(mktemp -d "${WORK_DIR%/}/tmpdir.azure-image.XXXXXX")"
TMPDIR="$(cd "$TMPDIR" && pwd)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Upload parameters:"
echo "  Subscription: ${SUBSCRIPTION_ID}"
echo "  Source: ${RAW:-$ACR_IMAGE}"
echo "  Build tag: ${BUILD_TAG} (commit ${COMMIT})"
echo "  Gallery: ${RESOURCE_GROUP}/${GALLERY}/${IMAGE_DEFINITION}/${IMAGE_VERSION}"
echo "  Staging blob: ${STORAGE_ACCOUNT}/${CONTAINER}/${BLOB_NAME}"
echo "  Target regions: ${TARGET_REGIONS}"
echo

echo "==> checking if image version exists: ${IMAGE_DEFINITION}/${IMAGE_VERSION}"
VERSION_EXISTS=0
if az sig image-version show \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION" >/dev/null 2>&1; then
  VERSION_EXISTS=1
fi

if [[ "$VERSION_EXISTS" -eq 1 ]] && [[ "$FORCE_OVERWRITE_IMAGE" -eq 0 ]]; then
  die "Image version ${IMAGE_DEFINITION}/${IMAGE_VERSION} already exists. Re-run with --force-overwrite-image to replace it."
fi

echo "==> ensuring resource group, gallery, image definition and storage account"
if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
  run az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
fi

if ! az sig show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY" >/dev/null 2>&1; then
  run az sig create --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY" --location "$LOCATION" -o none
fi

if ! az sig image-definition show \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" >/dev/null 2>&1; then
  run az sig image-definition create \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --location "$LOCATION" \
    --publisher superprotocol \
    --offer sp-vm \
    --sku "${IMAGE_DEFINITION#sp-vm-}" \
    --os-type Linux \
    --os-state Specialized \
    --hyper-v-generation V2 \
    --features "SecurityType=${SECURITY_TYPE}" \
    -o none
fi

if ! az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  run az storage account create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$STORAGE_ACCOUNT" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    -o none
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  STORAGE_KEY="<storage-account-key>"
else
  STORAGE_KEY="$(az storage account keys list \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT" \
    --query "[0].value" -o tsv)"
fi
run az storage container create \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --name "$CONTAINER" \
  -o none

if [[ -n "$ACR_IMAGE" ]]; then
  echo "==> pulling raw image from ${ACR_IMAGE}"
  run az acr login --name "${ACR_IMAGE%%.*}"
  run docker pull "$ACR_IMAGE"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    container_id="$(docker create "$ACR_IMAGE" /none)"
    docker export "$container_id" | tar -x -C "$TMPDIR" "sp-vm-${BUILD_TAG}.img" \
      || { docker rm "$container_id" >/dev/null; die "sp-vm-${BUILD_TAG}.img not found in ${ACR_IMAGE}"; }
    docker rm "$container_id" >/dev/null
  fi
  RAW="${TMPDIR}/sp-vm-${BUILD_TAG}.img"
fi

VHD="${TMPDIR}/${BLOB_NAME}"
if [[ "$DRY_RUN" -eq 0 ]]; then
  raw_size="$(stat -c %s "$RAW")"
  if (( raw_size % MIB != 0 )); then
    # Azure requires the virtual disk size to be a whole number of MiB.
    aligned_raw="${TMPDIR}/aligned.img"
    echo "==> aligning ${RAW} (${raw_size} bytes) to 1 MiB"
    cp --sparse=always "$RAW" "$aligned_raw"
    truncate -s $(( (raw_size + MIB - 1) / MIB * MIB )) "$aligned_raw"
    RAW="$aligned_raw"
  fi
fi

echo "==> converting raw image to fixed VHD"
if command -v qemu-img >/dev/null 2>&1; then
  run qemu-img convert -f raw -O vpc -o subformat=fixed,force_size "$RAW" "$VHD"
else
  need_cmd docker
  raw_dir="$(cd "$(dirname "$RAW")" && pwd)"
  run docker run --rm \
    -v "${raw_dir}:/in:ro" \
    -v "${TMPDIR}:/out" \
    ubuntu:24.04 \
    bash -c "apt-get update -qq >/dev/null \
      && apt-get install -y -qq qemu-utils >/dev/null \
      && qemu-img convert -f raw -O vpc -o subformat=fixed,force_size \
        '/in/$(basename "$RAW")' '/out/${BLOB_NAME}' \
      && chown $(id -u):$(id -g) '/out/${BLOB_NAME}'"
fi

echo "==> uploading VHD page blob to ${STORAGE_ACCOUNT}/${CONTAINER}/${BLOB_NAME}"
if command -v azcopy >/dev/null 2>&1; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    sas="<sas>"
  else
    sas="$(az storage container generate-sas \
      --account-name "$STORAGE_ACCOUNT" \
      --account-key "$STORAGE_KEY" \
      --name "$CONTAINER" \
      --permissions rcw \
      --expiry "$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%MZ')" \
      -o tsv)"
  fi
  run azcopy copy "$VHD" \
    "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}?${sas}" \
    --blob-type PageBlob
else
  run az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    --file "$VHD" \
    --type page \
    --overwrite \
    --max-connections 16 \
    --only-show-errors \
    -o none
fi
run rm -f "$VHD"

if [[ "$VERSION_EXISTS" -eq 1 ]]; then
  echo "==> deleting existing image version ${IMAGE_DEFINITION}/${IMAGE_VERSION}"
  run az sig image-version delete \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION"
fi

echo "==> creating image version ${IMAGE_DEFINITION}/${IMAGE_VERSION}"
# shellcheck disable=SC2086 # target regions are a space separated list
run az sig image-version create \
  --resource-group "$RESOURCE_GROUP" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --gallery-image-version "$IMAGE_VERSION" \
  --location "$LOCATION" \
  --os-vhd-uri "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}" \
  --os-vhd-storage-account "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" \
  --target-regions ${TARGET_REGIONS} \
  --tags "build_tag=${BUILD_TAG}" "commit=${COMMIT}" \
  -o none

if [[ "$KEEP_VHD" -eq 0 ]]; then
  echo "==> deleting staging blob ${BLOB_NAME}"
  run az storage blob delete \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    -o none
fi

IMAGE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY}/images/${IMAGE_DEFINITION}/versions/${IMAGE_VERSION}"

echo
echo "==> Image upload completed"
echo "  ${IMAGE_ID}"
echo
echo "Create a TDX Confidential VM (attach a data disk: the largest extra disk becomes the state disk):"
echo "  az vm create -g <rg> -n <vm> -l ${LOCATION} --zone 3 --size Standard_DC2es_v6 \\"
echo "    --image ${IMAGE_ID} --specialized \\"
echo "    --security-type ConfidentialVM --os-disk-security-encryption-type VMGuestStateOnly \\"
echo "    --enable-vtpm true --enable-secure-boot false \\"
echo "    --data-disk-sizes-gb 100"
