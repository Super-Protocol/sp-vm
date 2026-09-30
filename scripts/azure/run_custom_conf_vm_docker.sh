#!/usr/bin/env bash
set -euo pipefail

# Runs run_custom_conf_vm.sh inside a container (see docker_run.sh), so the
# host only needs Docker. All arguments are passed through.

exec "$(dirname "${BASH_SOURCE[0]}")/docker_run.sh" run_custom_conf_vm.sh \
  --file-arg --raw --dir-arg --work-dir --ro-dir-arg --provider-config \
  -- "$@"
