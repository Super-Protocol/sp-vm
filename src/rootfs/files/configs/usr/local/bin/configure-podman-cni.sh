#!/bin/bash
# Keep Podman CNI in /etc/cni/podman/net.d and Kubernetes CNI in /etc/cni/net.d only.
set -euo pipefail

PODMAN_CNI_DIR="/etc/cni/podman/net.d"
K8S_CNI_DIR="/etc/cni/net.d"
CONTAINERS_DROPIN="/etc/containers/containers.conf.d/99-podman-cni-dir.conf"
BUNDLED_PODMAN_CONFLIST="/etc/cni/podman/net.d/87-podman-bridge.conflist"

mkdir -p "$PODMAN_CNI_DIR" "$K8S_CNI_DIR" "$(dirname "$CONTAINERS_DROPIN")"

shopt -s nullglob
for f in \
  "$K8S_CNI_DIR"/*podman* \
  "$K8S_CNI_DIR"/87-podman-bridge.conflist \
  "$K8S_CNI_DIR"/05-cilium.conflist; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  dest="$PODMAN_CNI_DIR/$base"
  if [[ "$base" == 05-cilium.conflist ]]; then
    rm -f "$f"
    continue
  fi
  if [ ! -e "$dest" ]; then
    mv "$f" "$dest"
  else
    rm -f "$f"
  fi
done

if [ ! -f "$BUNDLED_PODMAN_CONFLIST" ]; then
  echo "configure-podman-cni: missing $BUNDLED_PODMAN_CONFLIST" >&2
  exit 1
fi

if [ ! -f "$CONTAINERS_DROPIN" ]; then
  cat >"$CONTAINERS_DROPIN" <<'EOF'
[network]
network_config_dir = "/etc/cni/podman/net.d"
default_network = "podman"
EOF
fi
