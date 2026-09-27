#!/usr/bin/env bash
set -euo pipefail

# Shared body of the *_docker.sh wrappers: runs one of the scripts in this
# directory inside a container with Azure CLI, azcopy, uplink and zstd, so the
# host only needs Docker.
#
#   docker_run.sh <script> [wrapper options] -- <script arguments>
#
# Wrapper options say which script arguments name host paths that must be
# visible in the container; they are mounted at the same path:
#   --file-arg <flag>    the directory of the file given to <flag>
#   --dir-arg <flag>     the directory given to <flag>, read-write
#   --ro-dir-arg <flag>  the directory given to <flag>, read-only
#   --mount <dir>        this host directory, read-write (created if missing)
#   --ro-mount <dir>     this host directory, read-only (skipped if missing)
#   --env <NAME>         pass this environment variable through
#
# The repository and the current directory are always mounted.
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

[[ $# -gt 0 ]] || die "usage: docker_run.sh <script> [options] -- <script arguments>"
TARGET="$1"; shift
[[ -x "${SCRIPT_DIR}/${TARGET}" ]] || die "Not an executable script in ${SCRIPT_DIR}: ${TARGET}"

file_args=() dir_args=() ro_dir_args=() extra_mounts=() ro_mounts=() env_names=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file-arg) file_args+=("$2"); shift 2 ;;
    --dir-arg) dir_args+=("$2"); shift 2 ;;
    --ro-dir-arg) ro_dir_args+=("$2"); shift 2 ;;
    --mount) extra_mounts+=("$2"); shift 2 ;;
    --ro-mount) ro_mounts+=("$2"); shift 2 ;;
    --env) env_names+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) die "docker_run.sh: unknown option $1" ;;
  esac
done

in_list() {
  local needle="$1" item; shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# Host paths are mounted at the same locations so relative and absolute
# arguments keep working inside the container.
mounts=(-v "${REPO_ROOT}:${REPO_ROOT}" -v "${PWD}:${PWD}")
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  flag="${args[i]}" value="${args[i + 1]:-}"
  [[ -n "$value" ]] || continue
  if in_list "$flag" "${file_args[@]}"; then
    dir="$(cd "$(dirname "$value")" && pwd)"
    mounts+=(-v "${dir}:${dir}")
  elif in_list "$flag" "${dir_args[@]}"; then
    [[ -d "$value" ]] || die "Directory not found: ${value} (${flag})"
    dir="$(cd "$value" && pwd)"
    mounts+=(-v "${dir}:${dir}")
  elif in_list "$flag" "${ro_dir_args[@]}"; then
    [[ -d "$value" ]] || die "Directory not found: ${value} (${flag})"
    dir="$(cd "$value" && pwd)"
    mounts+=(-v "${dir}:${dir}:ro")
  fi
done
for dir in "${extra_mounts[@]}"; do
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  mounts+=(-v "${dir}:${dir}")
done
for dir in "${ro_mounts[@]}"; do
  [[ -d "$dir" ]] || continue
  dir="$(cd "$dir" && pwd)"
  mounts+=(-v "${dir}:${dir}:ro")
done

echo "==> building ${IMAGE}" >&2
docker buildx build --load --quiet --tag "$IMAGE" "$SCRIPT_DIR" >/dev/null

env_args=(-e HOME=/tmp -e GITHUB_SHA -e PROVIDER_CONFIG_DIR)
for name in "${env_names[@]}"; do
  env_args+=(-e "$name")
done
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

# -i keeps stdin open for the scripts that ask for confirmation; -t only when
# both ends are a terminal, so captured output ($(...)) stays clean. --init
# forwards Ctrl-C to the script.
tty_args=(-i)
[[ -t 0 && -t 1 ]] && tty_args+=(-t)

exec docker run --rm --init "${tty_args[@]}" \
  --user "$(id -u):$(id -g)" \
  "${env_args[@]}" \
  "${mounts[@]}" \
  --workdir "$PWD" \
  "$IMAGE" \
  bash -c "set -euo pipefail; ${login}; exec \"\$0\" \"\$@\"" \
  "${SCRIPT_DIR}/${TARGET}" "$@"
