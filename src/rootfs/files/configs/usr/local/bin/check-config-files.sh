#!/bin/bash

set -euo pipefail;

# Define source and destination paths
declare -A files=(
    ["/etc/super/var/lib/rancher/rke2/rke2-pss.yaml"]="/var/lib/rancher/rke2/rke2-pss.yaml"
    #["/etc/super/var/lib/rancher/rke2/server/manifests/k8s.yaml"]="/var/lib/rancher/rke2/server/manifests/k8s.yaml"
    #["/etc/super/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"]="/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"
    ["/etc/super/etc/iscsi/iscsid.conf"]="/etc/iscsi/iscsid.conf"
    ["/etc/super/etc/iscsi/initiatorname.iscsi"]="/etc/iscsi/initiatorname.iscsi"
    ["/etc/super/etc/rancher/rke2/config.yaml"]="/etc/rancher/rke2/config.yaml"
    ["/etc/super/etc/rancher/rke2/registries.yaml"]="/etc/rancher/rke2/registries.yaml"
)

# Check and copy files if they do not exist
for src in "${!files[@]}"; do
    dest="${files[$src]}"
    dest_dir=$(dirname "$dest")
    # Create destination directory if it does not exist
    if [ ! -d "$dest_dir" ]; then
        mkdir -p "$dest_dir"
    fi
    # Skip if source template is absent (optional config)
    if [ ! -f "$src" ]; then
        echo "skip: source not found: $src"
        continue
    fi
    # Copy file if it does not exist at destination
    if [ ! -f "$dest" ]; then
        cp -v "$src" "$dest"
    fi
done

# this service is designed to start before rke2 creates own directories
mkdir -p "/var/lib/rancher/rke2/server/manifests";

# kubernetes main auto-apply manifest
K8S_MAIN_MANIFEST="/var/lib/rancher/rke2/server/manifests/k8s.yaml"

# Overriding hauler int IP
NODE_DEFAULT_IFACE="$({ ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | grep '.'; } || echo)";
NODE_IP=""
if [[ -n "$NODE_DEFAULT_IFACE" ]]; then
    NODE_IP="$({ ip a show "$NODE_DEFAULT_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | awk -F '/' '{print $1}'; } || echo)";
fi

if [[ ! -f "$K8S_MAIN_MANIFEST" ]] && [[ -n "$NODE_IP" ]]; then
    NODE_IP="$NODE_IP" \
        envsubst \
        '$NODE_IP' \
        < "/etc/super/var/lib/rancher/rke2/server/manifests/k8s.yaml" \
        > "$K8S_MAIN_MANIFEST";
fi
if [[ -n "$NODE_IP" ]] && [[ -f "$K8S_MAIN_MANIFEST" ]]; then
    CURRENT_REGISTRY_IP="$(grep -E '\W+([0-9.]+)\W+registry.superprotocol.local' "$K8S_MAIN_MANIFEST" | awk '{print $1}')";
    CURRENT_HAULER_IP="$(grep -E '\W+([0-9.]+)\W+hauler.local' "$K8S_MAIN_MANIFEST" | awk '{print $1}')";
    if [[ "$CURRENT_REGISTRY_IP" != "$NODE_IP" ]] || [[ "$CURRENT_HAULER_IP" != "$NODE_IP" ]]; then
        echo "Node IP changed! Setting $NODE_IP in $K8S_MAIN_MANIFEST, current: $CURRENT_REGISTRY_IP and $CURRENT_HAULER_IP";
        sed -E -i \
            -e "s|^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+hauler\.local|          $NODE_IP hauler.local|" \
            -e "s|^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+registry\.superprotocol\.local|          $NODE_IP registry.superprotocol.local|" \
            "$K8S_MAIN_MANIFEST";
    fi
fi

CMDLINE="$(cat /proc/cmdline)";
ARGO_BRANCH="main";

if [[ "$CMDLINE" == *"sp-debug=true"* ]]; then
    ARGO_BRANCH_CMDLINE="$({ grep -o 'argo_branch=[^ ]*' < /proc/cmdline | cut -d= -f2; } || echo)";
    if [[ -n "$ARGO_BRANCH_CMDLINE" ]]; then
        ARGO_BRANCH="$ARGO_BRANCH_CMDLINE"
    fi
fi

CURRENT_ARGO_BRANCH="$({ grep -E 'targetRevision\W+(\w+)' "$K8S_MAIN_MANIFEST" | awk '{print $2}'; } || echo)";
if [[ "$CURRENT_ARGO_BRANCH" != "$ARGO_BRANCH" ]]; then
    echo "Setting $ARGO_BRANCH in $K8S_MAIN_MANIFEST, current: $CURRENT_ARGO_BRANCH"
    sed -ri "s|targetRevision:\W+\w+|targetRevision: $ARGO_BRANCH|" "$K8S_MAIN_MANIFEST";
fi

# detect_cpu_type
CPU_TYPE_CONFIGMAP_MANIFEST="/var/lib/rancher/rke2/server/manifests/cpu-type-configmap.yaml";

# i can't cover this into function due using EOF mark, it will look ugly..
# at this moment other part of script was successfully executed, exit 0 will not break anyting
if [[ -f "$CPU_TYPE_CONFIGMAP_MANIFEST" ]]; then  # if already defined
    exit 0;
fi

# TODO: activate
#if [[ "$CMDLINE" == *"sp-debug=true"* ]]; then
#    CPU_TYPE="untrusted";
if [[ -c "/dev/tdx_guest" ]]; then
    CPU_TYPE="tdx";
elif [[ -c "/dev/sev-guest" ]]; then
    CPU_TYPE="sev-snp";
else
    CPU_TYPE="untrusted";
fi

cat <<EOF > "$CPU_TYPE_CONFIGMAP_MANIFEST";
apiVersion: v1
kind: ConfigMap
metadata:
  name: cpu-type
  namespace: super-protocol
data:
  cpu-type: "$CPU_TYPE"
EOF
