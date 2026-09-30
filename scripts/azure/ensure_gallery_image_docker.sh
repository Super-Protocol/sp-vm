#!/usr/bin/env bash
set -euo pipefail

# Runs ensure_gallery_image.sh inside a container (see docker_run.sh), so the
# host only needs Docker. All arguments are passed through.

exec "$(dirname "${BASH_SOURCE[0]}")/docker_run.sh" ensure_gallery_image.sh \
  --file-arg --raw --dir-arg --work-dir \
  -- "$@"
