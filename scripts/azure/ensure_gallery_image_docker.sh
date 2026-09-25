#!/usr/bin/env bash
set -euo pipefail

# Runs ensure_gallery_image.sh inside a container with Azure CLI, azcopy,
# uplink and zstd, so the host only needs Docker. All arguments are passed
# through.
#
# Authentication:
#   - AZURE_CREDENTIALS set (service principal JSON with clientId,
#     clientSecret, tenantId, subscriptionId): log in inside the container.
#   - otherwise: reuse the host `az login` session from ~/.azure
#     (or $AZURE_CONFIG_DIR).

die() { echo "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Command not found: docker"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE="${AZURE_TOOLS_IMAGE:-sp-vm-azure-tools:local}"

RAW=""
WORK_DIR=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --raw) RAW="${args[i + 1]:-}" ;;
    --work-dir) WORK_DIR="${args[i + 1]:-}" ;;
  esac
done

echo "==> building ${IMAGE}"
docker buildx build --load --quiet --tag "$IMAGE" "$SCRIPT_DIR" >/dev/null

# Host paths are mounted at the same locations so relative and absolute
# arguments keep working inside the container.
mounts=(-v "${REPO_ROOT}:${REPO_ROOT}" -v "${PWD}:${PWD}")
if [[ -n "$RAW" ]]; then
  raw_dir="$(cd "$(dirname "$RAW")" && pwd)"
  mounts+=(-v "${raw_dir}:${raw_dir}")
fi
if [[ -n "$WORK_DIR" ]]; then
  mounts+=(-v "$(cd "$WORK_DIR" && pwd):$(cd "$WORK_DIR" && pwd)")
fi

env_args=(-e HOME=/tmp -e GITHUB_SHA)
if [[ -n "${AZURE_CREDENTIALS:-}" ]]; then
  env_args+=(-e AZURE_CREDENTIALS -e AZURE_CONFIG_DIR=/tmp/.azure)
  # shellcheck disable=SC2016 # expanded inside the container
  login='az login --service-principal \
      --username "$(jq -r .clientId <<<"$AZURE_CREDENTIALS")" \
      --password "$(jq -r .clientSecret <<<"$AZURE_CREDENTIALS")" \
      --tenant "$(jq -r .tenantId <<<"$AZURE_CREDENTIALS")" \
      -o none
    az account set --subscription "$(jq -r .subscriptionId <<<"$AZURE_CREDENTIALS")"'
else
  host_config="${AZURE_CONFIG_DIR:-$HOME/.azure}"
  [[ -d "$host_config" ]] || die "No Azure session found in ${host_config} (run: az login) and AZURE_CREDENTIALS is not set"
  mounts+=(-v "${host_config}:/tmp/.azure")
  env_args+=(-e AZURE_CONFIG_DIR=/tmp/.azure)
  login=true
fi

exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  "${env_args[@]}" \
  "${mounts[@]}" \
  --workdir "$PWD" \
  "$IMAGE" \
  bash -c "set -euo pipefail; ${login}; exec \"\$0\" \"\$@\"" \
  "${SCRIPT_DIR}/ensure_gallery_image.sh" "$@"
