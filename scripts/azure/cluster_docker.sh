#!/usr/bin/env bash
set -euo pipefail

# Runs cluster.sh inside a container (see docker_run.sh), so the host only
# needs Docker. All arguments are passed through.
#
# Besides the paths given on the command line, the container needs the local
# cluster state and the provider_config template named in the specification
# or in that state; both are mounted at their host paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SP_VM_CLUSTER_STATE="${SP_VM_CLUSTER_STATE:-${HOME}/.sp-vm/azure-clusters}"
mkdir -p "$SP_VM_CLUSTER_STATE"
SP_VM_CLUSTER_STATE="$(cd "$SP_VM_CLUSTER_STATE" && pwd)"

templates=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  value="${args[i + 1]:-}"
  case "${args[i]}" in
    --spec)
      # provider_config of the specification, relative to the spec's directory.
      [[ -f "$value" ]] || continue
      template="$(sed -nE 's/^provider_config:[[:space:]]*["'\'']?([^"'\''#]*[^"'\''#[:space:]])["'\'']?.*$/\1/p' "$value" | head -1)"
      [[ -n "$template" ]] || continue
      [[ "$template" == /* ]] || template="$(cd "$(dirname "$value")" && pwd)/${template}"
      templates+=(--ro-mount "$template")
      ;;
    --cluster)
      state_spec="${SP_VM_CLUSTER_STATE}/${value}/spec.json"
      [[ -f "$state_spec" ]] || continue
      template="$(grep -oE '"provider_config": *"[^"]*"' "$state_spec" | head -1 | sed -E 's/.*: *"(.*)"/\1/')"
      [[ -z "$template" ]] || templates+=(--ro-mount "$template")
      ;;
  esac
done

exec "${SCRIPT_DIR}/docker_run.sh" cluster.sh \
  --file-arg --spec --ro-dir-arg --provider-config \
  --mount "$SP_VM_CLUSTER_STATE" --env SP_VM_CLUSTER_STATE \
  "${templates[@]}" \
  -- "$@"
