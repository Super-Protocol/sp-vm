#!/bin/bash

set -euo pipefail;

# this service is designed to start before rke2 creates own directories
mkdir -p "/var/lib/rancher/rke2/server/manifests";

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

# Check for CPU type override file first
CPU_TYPE_OVERRIDE_FILE="/sp/cpu_type_override"
if [[ -f "${CPU_TYPE_OVERRIDE_FILE}" ]]; then
    CPU_TYPE_OVERRIDE="$(cat "${CPU_TYPE_OVERRIDE_FILE}" | tr -d '[:space:]')"
    if [[ "${CPU_TYPE_OVERRIDE}" == "token" ]]; then
        CPU_TYPE="token"
    fi
fi

# If not set by override, use hardware detection
if [[ -z "${CPU_TYPE:-}" ]]; then
    if [[ -c "/dev/tdx_guest" ]]; then
        CPU_TYPE="tdx";
    elif [[ -c "/dev/sev-guest" ]]; then
        CPU_TYPE="sev-snp";
    else
        CPU_TYPE="untrusted";
    fi
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
