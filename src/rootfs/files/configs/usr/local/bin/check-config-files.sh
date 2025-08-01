#!/bin/bash

# Define source and destination paths
declare -A files=(
    ["/etc/super/var/lib/rancher/rke2/rke2-pss.yaml"]="/var/lib/rancher/rke2/rke2-pss.yaml"
    #["/etc/super/var/lib/rancher/rke2/server/manifests/k8s.yaml"]="/var/lib/rancher/rke2/server/manifests/k8s.yaml"
    #["/etc/super/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"]="/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"
    ["/etc/super/etc/iscsi/iscsid.conf"]="/etc/iscsi/iscsid.conf"
    ["/etc/super/etc/iscsi/initiatorname.iscsi"]="/etc/iscsi/initiatorname.iscsi"
)

# Check and copy files if they do not exist
for src in "${!files[@]}"; do
    dest="${files[$src]}"
    dest_dir=$(dirname "$dest")
    # Create destination directory if it does not exist
    if [ ! -d "$dest_dir" ]; then
        mkdir -p "$dest_dir"
    fi
    # Copy file if it does not exist
    if [ ! -f "$dest" ]; then
        cp -v "$src" "$dest"
    fi
done

# Overriding hauler int IP
NODE_DEFAULT_IFACE="$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | grep . )";
NODE_IP="$(ip a show $NODE_DEFAULT_IFACE | grep inet | grep -v inet6 | awk '{print $2}' | awk -F '/' '{print $1}')";

NODE_IP="$NODE_IP" \
    envsubst \
    '$NODE_IP' \
    < "/etc/super/var/lib/rancher/rke2/server/manifests/k8s.yaml" \
    > "/var/lib/rancher/rke2/server/manifests/k8s.yaml";

K8S="/var/lib/rancher/rke2/server/manifests/k8s.yaml"
CMDLINE="$(cat /proc/cmdline)"
ARGO_BRANCH="main"

if [[ "$CMDLINE" == *"sp-debug=true"* ]]; then
    ARGO_BRANCH_CMDLINE="$(cat /proc/cmdline | grep -o 'argo_branch=[^ ]*' | cut -d= -f2)"
    if [[ -n "$ARGO_BRANCH_CMDLINE" ]]; then
        ARGO_BRANCH="$ARGO_BRANCH_CMDLINE"
    fi
fi

CURRENT_ARGO_BRANCH="$(grep -E 'targetRevision\W+(\w+)' "$K8S" | awk '{print $2}')"
if [[ "$CURRENT_ARGO_BRANCH" != "$ARGO_BRANCH" ]]; then
    echo "Setting $ARGO_BRANCH in $K8S, current: $CURRENT_ARGO_BRANCH"
    sed -ri "s|targetRevision:\W+\w+|targetRevision: $ARGO_BRANCH|" "$K8S";
fi

# detect_cpu_type
CPU_TYPE_CONFIGMAP_MANIFEST="/var/lib/rancher/rke2/server/manifests/cpu-type-configmap.yaml";

# i can't cover this into function due using EOF mark, it will look ugly..
# at this moment other part of script was successfully executed, exit 0 will not break anyting
if [[ -f "$CPU_TYPE_CONFIGMAP_MANIFEST" ]]; then  # if already defined
    exit 0;
fi

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
