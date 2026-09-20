#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Make sure an sp-vm build is available as an Azure Compute Gallery image version
that can boot Confidential (TDX / SEV-SNP) and regular VMs, and print its id.

Nothing is downloaded or uploaded when a matching version already exists: the
version is located by build tag and its contents are confirmed by the
`image_sha256` tag. A missing region is replicated from the existing version,
and a copy in another gallery of the subscription is reused as the source.

Otherwise the image is fetched from Storj, verified against both hashes from
vm.json, turned into a fixed VHD, uploaded as a staging page blob, and imported
into the gallery. Azure accepts only VHD blobs as a source for CVM images.

Examples:
  ./ensure_gallery_image.sh --release build-441-release
  ./ensure_gallery_image.sh --vm-json ./vm.json --target-regions "westus3 eastus"
  ./ensure_gallery_image.sh --raw ./out/sp-vm-build-441-debug.img

Source (one of):
  --release <tag>    Read vm.json from the Super-Protocol/sp-vm release <tag>
  --vm-json <path|url> Read vm.json from a file or URL
  --raw <path>       Use a local sp-vm-<tag>.img (no download, no hash from vm.json)

Parameters:
  --build-tag <tag>  build-<N>-<debug|release>; default: from vm.json or the file name
  --resource-group <name> Default: sp-vm-images (or $AZURE_RESOURCE_GROUP)
  --location <region>     Default: westus3 (or $AZURE_LOCATION)
  --gallery <name>        Default: sp_vm_images (or $AZURE_GALLERY)
  --storage-account <name> Staging account for the VHD blob
                          (default: spvmimg<hash of subscription id>, or $AZURE_STORAGE_ACCOUNT)
  --target-regions <list> Space separated replication regions (default: --location)
  --security-type <type>  Image definition security type
                          (default: TrustedLaunchAndConfidentialVmSupported)
  --storj-access <grant>  Storj access grant (default: the public read-only grant, or $STORJ_ACCESS)
  --work-dir <path>       Where the archive and VHD are written (default: current directory)
  --keep-vhd              Keep the staging blob after the version is created
  --verify-upload         Read the staging blob back and compare its hash before creating the version
  --no-cross-gallery-search Do not look for the same image in other galleries
  --force-overwrite-image Recreate the version even if one with other contents exists
  --print-id-only         Print only the image version id on stdout (progress goes to stderr)
  --dry-run               Print commands without executing them

The image version is <N>.0.0 of image definition sp-vm-<debug|release>.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
PRINT_ID_ONLY=0
RAW=""
VM_JSON=""
RELEASE=""
BUILD_TAG=""
TARGET_REGIONS=""
STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
WORK_DIR="."
KEEP_VHD=0
VERIFY_UPLOAD=0
CROSS_GALLERY_SEARCH=1
FORCE_OVERWRITE_IMAGE=0
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-sp-vm-images}"
LOCATION="${AZURE_LOCATION:-westus3}"
GALLERY="${AZURE_GALLERY:-sp_vm_images}"
SECURITY_TYPE="TrustedLaunchAndConfidentialVmSupported"
CONTAINER="vhds"
RELEASE_REPO="Super-Protocol/sp-vm"
MIB=1048576
# Read-only access grant published with sp-vm-tools; override for other buckets.
STORJ_ACCESS="${STORJ_ACCESS:-1UXqNMwov41q9TgHmyopNg5q2giQ8aTdh1gjKWKjfbWPFrcrnhenp6QZfd5ukyVnYXDx9Cok6RtnQMMnXmoZPrSUMNGZGF9KuLCzvRNmQYHowX14C2xAxtJeH6VCuNX39ist4bRE9L5VT3k41frDVh3cG1gZvsqh4EaDeaJyV6U4xVaqXqULnSb9PozqU97VVLWhfwdnj6XgUM59Wzq7yo7vn8RxwSyn8H74TEiLNGUPPA3frsYZuoqWQkNzbiYev5ByWeLro1TXo7DogD4WALCKfEmpwHs9j9rsX5WZvvZ13ourTiuZp5vTTZkByB2ibxUJqkSoZSpCNVtmDToNVKkMREVySe}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW="${2:-}"; shift 2 ;;
    --vm-json) VM_JSON="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --build-tag) BUILD_TAG="${2:-}"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --gallery) GALLERY="${2:-}"; shift 2 ;;
    --storage-account) STORAGE_ACCOUNT="${2:-}"; shift 2 ;;
    --target-regions) TARGET_REGIONS="${2:-}"; shift 2 ;;
    --security-type) SECURITY_TYPE="${2:-}"; shift 2 ;;
    --storj-access) STORJ_ACCESS="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --keep-vhd) KEEP_VHD=1; shift 1 ;;
    --verify-upload) VERIFY_UPLOAD=1; shift 1 ;;
    --no-cross-gallery-search) CROSS_GALLERY_SEARCH=0; shift 1 ;;
    --force-overwrite-image) FORCE_OVERWRITE_IMAGE=1; shift 1 ;;
    --print-id-only) PRINT_ID_ONLY=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

# fd 3 is the real stdout. In --print-id-only mode everything the script would
# normally print is pushed to stderr, so stdout carries only the version id.
if [[ "$PRINT_ID_ONLY" -eq 1 ]]; then
  exec 3>&1 1>&2
else
  exec 3>&1
fi

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

json_get() {
  # json_get <file> <key-path...>: prints the value or nothing when absent
  python3 - "$@" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    node = json.load(f)
for key in sys.argv[2:]:
    if not isinstance(node, dict) or key not in node:
        sys.exit(0)
    node = node[key]
print(node)
PY
}

sources=0
[[ -z "$RAW" ]] || sources=$((sources + 1))
[[ -z "$VM_JSON" ]] || sources=$((sources + 1))
[[ -z "$RELEASE" ]] || sources=$((sources + 1))
(( sources == 1 )) || die "Provide exactly one of --raw, --vm-json, --release (see --help)"
[[ -d "$WORK_DIR" ]] || die "Work directory not found: $WORK_DIR"

need_cmd az
need_cmd python3
need_cmd sha256sum

az account show >/dev/null 2>&1 || die "Not logged in to Azure (run: az login)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
if [[ -z "$STORAGE_ACCOUNT" ]]; then
  STORAGE_ACCOUNT="spvmimg$(printf '%s' "$SUBSCRIPTION_ID" | sha256sum | cut -c1-10)"
fi

WORK_DIR="$(cd "$WORK_DIR" && pwd)"
TMPDIR="$(mktemp -d "${WORK_DIR}/tmpdir.azure-image.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

### Source description ########################################################

ARCHIVE_NAME=""
ARCHIVE_SHA256=""
IMAGE_SHA256=""
IMAGE_SIZE=""
STORJ_BUCKET=""
STORJ_PREFIX=""

if [[ -n "$RELEASE" ]]; then
  need_cmd curl
  BUILD_TAG="${BUILD_TAG:-$RELEASE}"
  VM_JSON="${TMPDIR}/vm.json"
  echo "==> fetching vm.json from release ${RELEASE}"
  curl -sfL -o "$VM_JSON" \
    "https://github.com/${RELEASE_REPO}/releases/download/${RELEASE}/vm.json" \
    || die "Cannot download vm.json for release ${RELEASE}"
elif [[ -n "$VM_JSON" && "$VM_JSON" =~ ^https?:// ]]; then
  need_cmd curl
  echo "==> fetching ${VM_JSON}"
  curl -sfL -o "${TMPDIR}/vm.json" "$VM_JSON" || die "Cannot download ${VM_JSON}"
  VM_JSON="${TMPDIR}/vm.json"
fi

if [[ -n "$VM_JSON" ]]; then
  [[ -f "$VM_JSON" ]] || die "vm.json not found: $VM_JSON"
  STORJ_BUCKET="$(json_get "$VM_JSON" image bucket)"
  STORJ_PREFIX="$(json_get "$VM_JSON" image prefix)"
  ARCHIVE_NAME="$(json_get "$VM_JSON" image filename)"
  ARCHIVE_SHA256="$(json_get "$VM_JSON" image sha256)"
  compression="$(json_get "$VM_JSON" image compression)"
  IMAGE_SHA256="$(json_get "$VM_JSON" image uncompressed_sha256)"
  IMAGE_SIZE="$(json_get "$VM_JSON" image uncompressed_size)"
  BUILD_TAG="${BUILD_TAG:-$STORJ_PREFIX}"

  [[ -n "$ARCHIVE_NAME" && -n "$ARCHIVE_SHA256" ]] \
    || die "vm.json has no image entry with bucket/prefix/filename/sha256"
  [[ "$compression" == "zstd" ]] \
    || die "vm.json image compression is '${compression:-none}'; only zstd builds are supported"
  [[ -n "$IMAGE_SHA256" && -n "$IMAGE_SIZE" ]] \
    || die "vm.json image entry has no uncompressed_sha256/uncompressed_size"
elif [[ -n "$RAW" ]]; then
  [[ -f "$RAW" ]] || die "Raw image not found: $RAW"
  RAW="$(cd "$(dirname "$RAW")" && pwd)/$(basename "$RAW")"
  if [[ -z "$BUILD_TAG" ]]; then
    BUILD_TAG="$(basename "$RAW" .img)"
    BUILD_TAG="${BUILD_TAG#sp-vm-}"
  fi
  IMAGE_SIZE="$(stat --format='%s' "$RAW")"
  echo "==> hashing ${RAW}"
  IMAGE_SHA256="$(sha256sum "$RAW" | awk '{print $1}')"
fi

[[ "$BUILD_TAG" =~ ^build-([0-9]+)-(debug|release)$ ]] \
  || die "Cannot derive build tag (expected build-<N>-<debug|release>, got '${BUILD_TAG}'); pass --build-tag"
IMAGE_DEFINITION="sp-vm-${BASH_REMATCH[2]}"
IMAGE_VERSION="${BASH_REMATCH[1]}.0.0"
TARGET_REGIONS="${TARGET_REGIONS:-$LOCATION}"
BLOB_NAME="${IMAGE_DEFINITION}-${IMAGE_VERSION}-${IMAGE_SHA256}.vhd"
VERSION_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY}/images/${IMAGE_DEFINITION}/versions/${IMAGE_VERSION}"

echo "Parameters:"
echo "  Subscription:   ${SUBSCRIPTION_ID}"
echo "  Build:          ${BUILD_TAG} -> ${IMAGE_DEFINITION}:${IMAGE_VERSION}"
echo "  Image sha256:   ${IMAGE_SHA256}"
echo "  Gallery:        ${RESOURCE_GROUP}/${GALLERY}"
echo "  Target regions: ${TARGET_REGIONS}"
echo

### Gallery helpers ###########################################################

version_field() {
  az sig image-version show \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION" \
    --query "$1" -o tsv 2>/dev/null
}

# Prints the final provisioning state; progress goes to stderr so that callers
# can capture the state itself.
wait_while_creating() {
  local state
  while true; do
    state="$(version_field provisioningState)"
    [[ "$state" == "Creating" || "$state" == "Updating" ]] || break
    echo "    version is ${state}, waiting..." >&2
    sleep 20
  done
  printf '%s' "$state"
}

delete_version() {
  run az sig image-version delete \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION" \
    -o none
}

# Replicates the version to every target region, reusing the data already in
# the gallery; nothing is downloaded or uploaded.
ensure_regions() {
  local regions=() missing=() region failed

  # Azure reports region names as "West US 3"; normalize them to "westus3".
  mapfile -t regions < <(version_field "publishingProfile.targetRegions[].name" \
    | tr -d '\r' | tr '[:upper:]' '[:lower:]' | tr -d ' ')

  for region in $TARGET_REGIONS; do
    printf '%s\n' "${regions[@]}" | grep -qx "$region" || missing+=("$region")
  done

  failed="$(az sig image-version show \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION" \
    --expand ReplicationStatus \
    --query "replicationStatus.summary[?state=='Failed'].region" -o tsv 2>/dev/null | tr -d '\r')"

  if [[ ${#missing[@]} -eq 0 && -z "$failed" ]]; then
    return 0
  fi
  if [[ -n "$failed" ]]; then
    echo "==> replication failed in: ${failed//$'\n'/ }; requesting it again"
  fi

  regions+=("${missing[@]}")
  echo "==> replicating inside Azure to: ${regions[*]}"
  run az sig image-version update \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION" \
    --target-regions "${regions[@]}" \
    -o none
}

finish() {
  # With --print-id-only stdout carries nothing but the id, so callers such as
  # run_custom_conf_vm.sh can capture it instead of scraping the log.
  if [[ "$PRINT_ID_ONLY" -eq 1 ]]; then
    printf '%s\n' "$VERSION_ID" >&3
    exit 0
  fi
  echo
  echo "==> image version ready"
  echo "  ${VERSION_ID}"
  echo
  echo "Create a TDX Confidential VM (the largest extra disk becomes the state disk):"
  echo "  az vm create -g <rg> -n <vm> -l ${LOCATION} --zone 3 --size Standard_DC2es_v6 \\"
  echo "    --image ${VERSION_ID} --specialized \\"
  echo "    --security-type ConfidentialVM --os-disk-security-encryption-type VMGuestStateOnly \\"
  echo "    --enable-vtpm true --enable-secure-boot false \\"
  echo "    --data-disk-sizes-gb 100"
  exit 0
}

### Is the image already there? ###############################################

echo "==> checking ${IMAGE_DEFINITION}:${IMAGE_VERSION}"
STATE="$(wait_while_creating)"
case "$STATE" in
  "")
    echo "    not found"
    ;;
  Succeeded)
    existing_sha="$(version_field 'tags.image_sha256')"
    if [[ "$existing_sha" == "$IMAGE_SHA256" ]]; then
      echo "    already present with matching image_sha256"
      ensure_regions
      finish
    fi
    if [[ "$FORCE_OVERWRITE_IMAGE" -eq 0 ]]; then
      die "Version ${IMAGE_DEFINITION}:${IMAGE_VERSION} exists with image_sha256='${existing_sha:-none}', expected '${IMAGE_SHA256}'. VMs may be running from it; re-run with --force-overwrite-image to replace it."
    fi
    echo "    contents differ, --force-overwrite-image given: deleting"
    delete_version
    ;;
  Failed)
    echo "    previous attempt failed: deleting and creating again"
    delete_version
    ;;
  *)
    die "Unexpected provisioning state '${STATE}' for ${IMAGE_DEFINITION}:${IMAGE_VERSION}"
    ;;
esac

### Prepare the gallery #######################################################

echo "==> ensuring resource group, gallery and image definition"
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

create_version() {
  # create_version [extra az arguments...]
  local rc=0
  # shellcheck disable=SC2086 # target regions are a space separated list
  run az sig image-version create \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$IMAGE_DEFINITION" \
    --gallery-image-version "$IMAGE_VERSION" \
    --location "$LOCATION" \
    --target-regions $TARGET_REGIONS \
    --block-deletion-before-end-of-life false \
    --tags "build_tag=${BUILD_TAG}" "image_sha256=${IMAGE_SHA256}" \
    "$@" \
    -o none || rc=$?
  return $rc
}

# A parallel run may have created the version in the meantime.
recheck_after_race() {
  local state
  state="$(wait_while_creating)"
  if [[ "$state" == "Succeeded" ]] && [[ "$(version_field 'tags.image_sha256')" == "$IMAGE_SHA256" ]]; then
    echo "==> another run created the same version"
    ensure_regions
    finish
  fi
  return 1
}

### Reuse a copy from another gallery #########################################

if [[ "$CROSS_GALLERY_SEARCH" -eq 1 ]] && [[ "$DRY_RUN" -eq 0 ]]; then
  echo "==> looking for the same image in other galleries of the subscription"
  SOURCE_VERSION_ID=""
  while IFS=$'\t' read -r gallery_rg gallery_name; do
    [[ -n "$gallery_name" ]] || continue
    [[ "$gallery_rg/$gallery_name" != "$RESOURCE_GROUP/$GALLERY" ]] || continue
    found="$(az sig image-version list \
      --resource-group "$gallery_rg" \
      --gallery-name "$gallery_name" \
      --gallery-image-definition "$IMAGE_DEFINITION" \
      --query "[?provisioningState=='Succeeded' && tags.image_sha256=='${IMAGE_SHA256}'].id | [0]" \
      -o tsv 2>/dev/null || true)"
    if [[ -n "$found" && "$found" != "None" ]]; then
      SOURCE_VERSION_ID="$found"
      break
    fi
  done < <(az sig list --query "[].[resourceGroup,name]" -o tsv)

  if [[ -n "$SOURCE_VERSION_ID" ]]; then
    echo "    found ${SOURCE_VERSION_ID}; copying it inside Azure"
    if create_version --image-version "$SOURCE_VERSION_ID"; then
      finish
    fi
    recheck_after_race || die "Failed to copy the existing version"
  fi
  echo "    not found"
fi

### Fetch, convert and upload #################################################

VHD="${TMPDIR}/${BLOB_NAME}"

if [[ "$DRY_RUN" -eq 0 ]]; then
  need_space=$IMAGE_SIZE
  [[ -z "$ARCHIVE_NAME" ]] || need_space=$((IMAGE_SIZE * 2))
  avail="$(df --output=avail -B1 "$TMPDIR" | tail -n1 | tr -d ' ')"
  (( avail >= need_space )) \
    || die "Not enough free space in ${WORK_DIR}: need ${need_space} bytes, have ${avail}"
fi

if [[ -n "$ARCHIVE_NAME" ]]; then
  need_cmd uplink
  need_cmd zstd
  ARCHIVE="${TMPDIR}/${ARCHIVE_NAME}"
  echo "==> downloading sj://${STORJ_BUCKET}/${STORJ_PREFIX}/${ARCHIVE_NAME}"
  run uplink cp \
    --parallelism 16 --interactive=false --analytics=false --progress \
    --access "$STORJ_ACCESS" \
    "sj://${STORJ_BUCKET}/${STORJ_PREFIX}/${ARCHIVE_NAME}" "$ARCHIVE"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "==> verifying archive checksum"
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    [[ "$actual" == "$ARCHIVE_SHA256" ]] \
      || die "Archive checksum mismatch: expected ${ARCHIVE_SHA256}, got ${actual}"
  fi

  echo "==> unpacking into ${BLOB_NAME}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run zstd -dc "$ARCHIVE" ">" "$VHD"
  else
    zstd -dc -- "$ARCHIVE" > "$VHD" || die "Failed to unpack ${ARCHIVE_NAME}"
    rm -f "$ARCHIVE"
  fi
else
  echo "==> copying ${RAW} to ${BLOB_NAME}"
  run cp --sparse=always "$RAW" "$VHD"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "==> verifying image checksum"
  actual="$(sha256sum "$VHD" | awk '{print $1}')"
  [[ "$actual" == "$IMAGE_SHA256" ]] \
    || die "Image checksum mismatch: expected ${IMAGE_SHA256}, got ${actual}"

  size="$(stat --format='%s' "$VHD")"
  if (( size % MIB )); then
    # Azure requires the virtual disk size to be a whole number of MiB.
    echo "==> padding ${size} bytes to a whole MiB"
    truncate -s $(( (size + MIB - 1) / MIB * MIB )) "$VHD"
  fi
fi

echo "==> appending fixed VHD footer"
run python3 "${SCRIPT_DIR}/vhd_footer.py" "$VHD"

### Staging blob ##############################################################

echo "==> ensuring staging storage account ${STORAGE_ACCOUNT}"
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

blob_property() {
  az storage blob show \
    --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" --name "$BLOB_NAME" \
    --query "$1" -o tsv 2>/dev/null
}

VHD_SIZE=0
[[ "$DRY_RUN" -eq 1 ]] || VHD_SIZE="$(stat --format='%s' "$VHD")"

# The blob name carries the image hash, so a blob of the same size is the same
# image and does not have to be uploaded again.
if [[ "$(blob_property properties.contentLength)" == "$VHD_SIZE" ]]; then
  echo "==> staging blob already uploaded"
else
  echo "==> uploading ${BLOB_NAME} (${VHD_SIZE} bytes)"
  if command -v azcopy >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      sas="<sas>"
    else
      sas="$(az storage container generate-sas \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --name "$CONTAINER" \
        --permissions rcw \
        --expiry "$(date -u -d '+6 hours' '+%Y-%m-%dT%H:%MZ')" \
        -o tsv)"
    fi
    run azcopy copy "$VHD" \
      "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}?${sas}" \
      --blob-type PageBlob --output-level essential
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
      --no-progress \
      --only-show-errors \
      -o none
  fi
fi

if [[ "$VERIFY_UPLOAD" -eq 1 ]] && [[ "$DRY_RUN" -eq 0 ]]; then
  echo "==> reading the staging blob back to verify it"
  az storage blob download \
    --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" --name "$BLOB_NAME" \
    --file "${TMPDIR}/verify.vhd" --max-connections 16 \
    --no-progress --only-show-errors -o none
  cmp "$VHD" "${TMPDIR}/verify.vhd" || die "Staging blob differs from the local VHD"
  rm -f "${TMPDIR}/verify.vhd"
fi

rm -f "$VHD"

### Create the version ########################################################

echo "==> creating image version ${IMAGE_DEFINITION}:${IMAGE_VERSION}"
if ! create_version \
    --os-vhd-uri "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}" \
    --os-vhd-storage-account "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"; then
  recheck_after_race || die "Failed to create image version ${IMAGE_DEFINITION}:${IMAGE_VERSION}"
fi

if [[ "$KEEP_VHD" -eq 0 ]]; then
  echo "==> deleting staging blob"
  run az storage blob delete \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    -o none
fi

finish
