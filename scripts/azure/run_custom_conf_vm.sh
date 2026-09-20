#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Launch an sp-vm TDX Confidential VM on Azure and hand it the operator's
provider_config.

Everything belonging to one launch lives in its own resource group (VM, OS
disk, state disk, NIC, public IP and the storage account holding the
provider_config archive), so --delete removes all of it in one operation.

The provider_config directory is packed into a tar.gz, uploaded as a blob and
handed to the guest as a read-only SAS URL in the VM's userData. The guest
downloads it once, verifies its sha256 and unpacks it into /sp. A lifecycle
rule on the storage account deletes the archive a day later.

NOTE: the VM does not survive a reboot. Its state disk is wiped and re-encrypted
with a fresh key on every boot, so /sp is empty again and the archive may
already be gone. Re-run this script to launch a fresh VM.

Examples:
  ./run_custom_conf_vm.sh --release build-441-debug --provider-config ./provider_config
  ./run_custom_conf_vm.sh --image <version-id> --vm my-vm --state-disk-size 200
  ./run_custom_conf_vm.sh --vm my-vm --delete

Image source (one of; passed through to ensure_gallery_image.sh):
  --release <tag>        Read vm.json from the Super-Protocol/sp-vm release <tag>
  --vm-json <path|url>   Read vm.json from a file or URL
  --raw <path>           Use a local sp-vm-<tag>.img
  --image <version-id>   Use an existing gallery image version, skip the upload step

VM:
  --vm <name>                 Default: sp-conf-vm
  --vm-resource-group <name>  Default: sp-vm-<vm name>
  --location <region>         Default: westus3 (or $AZURE_LOCATION)
  --zone <n>                  Default: 3
  --size <vm-size>            Default: Standard_DC2es_v6
  --state-disk-size <GB>      Default: 100
  --no-public-ip
  --force-overwrite-vm        Delete an existing VM of that name first

Gallery (only used when the image has to be ensured):
  --gallery <name>                 Default: sp_vm_images (or $AZURE_GALLERY)
  --gallery-resource-group <name>  Default: sp-vm-images (or $AZURE_RESOURCE_GROUP)

provider_config:
  --provider-config <dir>  Default: <script dir>/provider_config ($PROVIDER_CONFIG_DIR)
  --skip-provider-config   Launch without one (the VM will wait for it forever)
  --config-ttl-days <n>    Lifecycle rule deleting the archive; default 1
  --sas-expiry-days <n>    SAS lifetime; default 30. Keep it above --config-ttl-days
                           so the lifecycle rule stays the only real deadline
  --refresh-provider-config  Re-upload the archive and update an existing VM's userData

Other:
  --delete     Delete the VM's whole resource group and exit
  --dry-run    Print commands without executing them
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
RAW=""
VM_JSON=""
RELEASE=""
IMAGE_ID=""
VM_NAME="sp-conf-vm"
VM_RESOURCE_GROUP=""
LOCATION="${AZURE_LOCATION:-westus3}"
ZONE="3"
VM_SIZE="Standard_DC2es_v6"
STATE_DISK_SIZE="100"
NO_PUBLIC_IP=0
FORCE_OVERWRITE_VM=0
GALLERY="${AZURE_GALLERY:-sp_vm_images}"
GALLERY_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-sp-vm-images}"
PROVIDER_CONFIG_DIR="${PROVIDER_CONFIG_DIR:-}"
SKIP_PROVIDER_CONFIG=0
CONFIG_TTL_DAYS="1"
SAS_EXPIRY_DAYS="30"
REFRESH_PROVIDER_CONFIG=0
DELETE=0
CONTAINER="provider-config"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --vm-json) VM_JSON="${2:-}"; shift 2 ;;
    --raw) RAW="${2:-}"; shift 2 ;;
    --image) IMAGE_ID="${2:-}"; shift 2 ;;
    --vm) VM_NAME="${2:-}"; shift 2 ;;
    --vm-resource-group) VM_RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --zone) ZONE="${2:-}"; shift 2 ;;
    --size) VM_SIZE="${2:-}"; shift 2 ;;
    --state-disk-size) STATE_DISK_SIZE="${2:-}"; shift 2 ;;
    --no-public-ip) NO_PUBLIC_IP=1; shift 1 ;;
    --force-overwrite-vm) FORCE_OVERWRITE_VM=1; shift 1 ;;
    --gallery) GALLERY="${2:-}"; shift 2 ;;
    --gallery-resource-group) GALLERY_RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --provider-config) PROVIDER_CONFIG_DIR="${2:-}"; shift 2 ;;
    --skip-provider-config) SKIP_PROVIDER_CONFIG=1; shift 1 ;;
    --config-ttl-days) CONFIG_TTL_DAYS="${2:-}"; shift 2 ;;
    --sas-expiry-days) SAS_EXPIRY_DAYS="${2:-}"; shift 2 ;;
    --refresh-provider-config) REFRESH_PROVIDER_CONFIG=1; shift 1 ;;
    --delete) DELETE=1; shift 1 ;;
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

[[ -n "$VM_NAME" ]] || die "--vm must not be empty"
VM_RESOURCE_GROUP="${VM_RESOURCE_GROUP:-sp-vm-${VM_NAME}}"
PROVIDER_CONFIG_DIR="${PROVIDER_CONFIG_DIR:-${SCRIPT_DIR}/provider_config}"

need_cmd az
need_cmd sha256sum
need_cmd tar

az account show >/dev/null 2>&1 || die "Not logged in to Azure (run: az login)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

# Globally unique, <=24 chars, lowercase alphanumeric only.
STORAGE_ACCOUNT="spvmcfg$(printf '%s/%s' "$SUBSCRIPTION_ID" "$VM_NAME" | sha256sum | cut -c1-17)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

### Teardown ##################################################################

if [[ "$DELETE" -eq 1 ]]; then
  if ! az group show -n "$VM_RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Resource group ${VM_RESOURCE_GROUP} does not exist, nothing to delete"
    exit 0
  fi
  echo "==> deleting resource group ${VM_RESOURCE_GROUP} (VM, disks, NIC, IP and the provider_config storage account)"
  run az group delete -n "$VM_RESOURCE_GROUP" --yes -o none
  echo "==> deleted"
  exit 0
fi

### Image #####################################################################

sources=0
[[ -z "$RAW" ]] || sources=$((sources + 1))
[[ -z "$VM_JSON" ]] || sources=$((sources + 1))
[[ -z "$RELEASE" ]] || sources=$((sources + 1))
[[ -z "$IMAGE_ID" ]] || sources=$((sources + 1))
if [[ "$REFRESH_PROVIDER_CONFIG" -eq 0 ]]; then
  (( sources == 1 )) || die "Provide exactly one of --release, --vm-json, --raw, --image (see --help)"
else
  (( sources == 0 )) || die "--refresh-provider-config works on an existing VM; do not pass an image source"
fi

echo "Parameters:"
echo "  Subscription:   ${SUBSCRIPTION_ID}"
echo "  VM:             ${VM_NAME} (${VM_SIZE}, ${LOCATION} zone ${ZONE})"
echo "  Resource group: ${VM_RESOURCE_GROUP}"
echo "  Storage:        ${STORAGE_ACCOUNT}/${CONTAINER}"
if [[ "$SKIP_PROVIDER_CONFIG" -eq 0 ]]; then
  echo "  Provider config: ${PROVIDER_CONFIG_DIR}"
fi
echo

if [[ "$REFRESH_PROVIDER_CONFIG" -eq 0 ]] && [[ -z "$IMAGE_ID" ]]; then
  echo "==> making sure the image version exists in the gallery"
  source_args=()
  [[ -z "$RELEASE" ]] || source_args+=(--release "$RELEASE")
  [[ -z "$VM_JSON" ]] || source_args+=(--vm-json "$VM_JSON")
  [[ -z "$RAW" ]] || source_args+=(--raw "$RAW")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run "${SCRIPT_DIR}/ensure_gallery_image.sh" "${source_args[@]}" \
      --resource-group "$GALLERY_RESOURCE_GROUP" \
      --location "$LOCATION" \
      --gallery "$GALLERY" \
      --print-id-only
    IMAGE_ID="<image-version-id>"
  else
    IMAGE_ID="$("${SCRIPT_DIR}/ensure_gallery_image.sh" "${source_args[@]}" \
      --resource-group "$GALLERY_RESOURCE_GROUP" \
      --location "$LOCATION" \
      --gallery "$GALLERY" \
      --print-id-only)"
    [[ -n "$IMAGE_ID" ]] || die "ensure_gallery_image.sh did not return an image version id"
  fi
fi

### provider_config payload ###################################################

USER_DATA_FILE="${TMPDIR}/userdata.json"
BLOB_NAME=""

prepare_provider_config() {
  local archive sha256 expiry sas_url storage_key policy_file

  [[ -d "$PROVIDER_CONFIG_DIR" ]] \
    || die "Provider config directory not found: ${PROVIDER_CONFIG_DIR} (use --provider-config or --skip-provider-config)"
  [[ -n "$(ls -A "$PROVIDER_CONFIG_DIR" 2>/dev/null)" ]] \
    || die "Provider config directory is empty: ${PROVIDER_CONFIG_DIR}"
  if [[ ! -f "${PROVIDER_CONFIG_DIR}/swarm/config.yaml" ]]; then
    echo "WARNING: ${PROVIDER_CONFIG_DIR}/swarm/config.yaml is missing; the VM will not start swarm services" >&2
  fi

  echo "==> packing ${PROVIDER_CONFIG_DIR}"
  archive="${TMPDIR}/provider_config.tar.gz"
  # "-C dir ." so the archive root is what becomes /sp
  tar -czf "$archive" -C "$PROVIDER_CONFIG_DIR" .
  sha256="$(sha256sum "$archive" | awk '{print $1}')"

  echo "==> ensuring storage account ${STORAGE_ACCOUNT}"
  if ! az storage account show -g "$VM_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
    run az storage account create \
      -g "$VM_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -l "$LOCATION" \
      --sku Standard_LRS --kind StorageV2 \
      --min-tls-version TLS1_2 \
      --allow-blob-public-access false \
      -o none \
      || die "Failed to create storage account ${STORAGE_ACCOUNT} (the name must be globally unique)"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    storage_key="<storage-key>"
  else
    storage_key="$(az storage account keys list -g "$VM_RESOURCE_GROUP" \
      -n "$STORAGE_ACCOUNT" --query "[0].value" -o tsv)"
  fi

  run az storage container create \
    --account-name "$STORAGE_ACCOUNT" --account-key "$storage_key" \
    --name "$CONTAINER" --public-access off -o none

  # The archive is the only thing in this account, so the rule cannot reach
  # anything else; the filters are belt and braces.
  echo "==> setting the ${CONFIG_TTL_DAYS}-day lifecycle rule"
  policy_file="${TMPDIR}/lifecycle.json"
  cat >"$policy_file" <<EOF
{
  "rules": [
    {
      "enabled": true,
      "name": "expire-provider-config",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["${CONTAINER}/"]
        },
        "actions": {
          "baseBlob": {
            "delete": { "daysAfterCreationGreaterThan": ${CONFIG_TTL_DAYS} }
          }
        }
      }
    }
  ]
}
EOF
  run az storage account management-policy create \
    -g "$VM_RESOURCE_GROUP" --account-name "$STORAGE_ACCOUNT" \
    --policy "@${policy_file}" -o none

  BLOB_NAME="${VM_NAME}-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  echo "==> uploading ${BLOB_NAME}"
  run az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" --account-key "$storage_key" \
    --container-name "$CONTAINER" --name "$BLOB_NAME" \
    --file "$archive" --overwrite \
    --no-progress --only-show-errors -o none

  expiry="$(date -u -d "+${SAS_EXPIRY_DAYS} days" '+%Y-%m-%dT%H:%MZ')"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    sas_url="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}?<sas>"
  else
    sas_url="$(az storage blob generate-sas \
      --account-name "$STORAGE_ACCOUNT" --account-key "$storage_key" \
      --container-name "$CONTAINER" --name "$BLOB_NAME" \
      --permissions r --expiry "$expiry" --https-only --full-uri -o tsv)"
  fi

  umask 077
  cat >"$USER_DATA_FILE" <<EOF
{
  "provider_config": {
    "url": "${sas_url}",
    "sha256": "${sha256}"
  }
}
EOF
}

### Refresh an existing VM ####################################################

if [[ "$REFRESH_PROVIDER_CONFIG" -eq 1 ]]; then
  az vm show -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1 \
    || die "VM ${VM_NAME} not found in ${VM_RESOURCE_GROUP}"
  prepare_provider_config
  echo "==> updating userData"
  run az vm update -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" \
    --user-data "$USER_DATA_FILE" -o none
  echo "==> restarting ${VM_NAME} so it picks the new provider_config up"
  run az vm restart -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" -o none
  echo
  echo "==> provider_config refreshed"
  exit 0
fi

### Create ####################################################################

echo "==> ensuring resource group ${VM_RESOURCE_GROUP}"
run az group create -n "$VM_RESOURCE_GROUP" -l "$LOCATION" -o none

if az vm show -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  if [[ "$FORCE_OVERWRITE_VM" -eq 1 ]]; then
    echo "==> deleting the existing VM ${VM_NAME}"
    run az vm delete -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" --yes -o none
  else
    die "VM ${VM_NAME} already exists in ${VM_RESOURCE_GROUP} (use --force-overwrite-vm or --delete)"
  fi
fi

if [[ "$SKIP_PROVIDER_CONFIG" -eq 0 ]]; then
  prepare_provider_config
else
  echo "WARNING: launching without a provider_config; the guest will wait for /sp forever" >&2
fi

# `az vm create` insists on an SSH key for a Linux VM even though --specialized
# makes it drop the whole osProfile, so the key never reaches Azure. Without
# this it would silently pick up ~/.ssh/id_rsa.pub, which is absent in the
# container. Real VM access comes from /sp/authorized_keys in the provider
# config, which is what sshd reads.
echo "==> creating ${VM_NAME}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  THROWAWAY_KEY="${TMPDIR}/unused_vm_key.pub"
else
  need_cmd ssh-keygen
  ssh-keygen -t ed25519 -N '' -C 'unused-specialized-image-placeholder' \
    -f "${TMPDIR}/unused_vm_key" -q
  THROWAWAY_KEY="${TMPDIR}/unused_vm_key.pub"
fi

create_args=(
  az vm create
  -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" -l "$LOCATION"
  --zone "$ZONE" --size "$VM_SIZE"
  --image "$IMAGE_ID" --specialized
  --security-type ConfidentialVM
  --os-disk-security-encryption-type VMGuestStateOnly
  --enable-vtpm true --enable-secure-boot false
  --os-disk-delete-option Delete
  --nic-delete-option Delete
  --ssh-key-values "$THROWAWAY_KEY"
)
if [[ "$STATE_DISK_SIZE" != "0" ]]; then
  create_args+=(--data-disk-sizes-gb "$STATE_DISK_SIZE" --data-disk-delete-option Delete)
fi
if [[ "$NO_PUBLIC_IP" -eq 1 ]]; then
  create_args+=(--public-ip-address "")
else
  create_args+=(--public-ip-sku Standard)
fi
if [[ "$SKIP_PROVIDER_CONFIG" -eq 0 ]]; then
  create_args+=(--user-data "$USER_DATA_FILE")
fi
create_args+=(-o none)

run "${create_args[@]}"

PUBLIC_IP=""
if [[ "$DRY_RUN" -eq 0 ]] && [[ "$NO_PUBLIC_IP" -eq 0 ]]; then
  PUBLIC_IP="$(az vm show -d -g "$VM_RESOURCE_GROUP" -n "$VM_NAME" \
    --query publicIps -o tsv 2>/dev/null || true)"
fi

echo
echo "==> VM ready"
echo "  Name:           ${VM_NAME}"
echo "  Resource group: ${VM_RESOURCE_GROUP}"
echo "  Image version:  ${IMAGE_ID}"
[[ -z "$PUBLIC_IP" ]] || echo "  Public IP:      ${PUBLIC_IP}"
[[ -z "$BLOB_NAME" ]] || echo "  Config blob:    ${CONTAINER}/${BLOB_NAME} (deleted after ${CONFIG_TTL_DAYS}d)"
echo
echo "Serial console:"
echo "  az serial-console connect -g ${VM_RESOURCE_GROUP} -n ${VM_NAME}"
echo
echo "Delete everything (VM, disks, NIC, IP, config storage):"
echo "  ${BASH_SOURCE[0]} --vm ${VM_NAME} --vm-resource-group ${VM_RESOURCE_GROUP} --delete"
echo
echo "The VM does not survive a reboot: its state disk is wiped on every boot."
