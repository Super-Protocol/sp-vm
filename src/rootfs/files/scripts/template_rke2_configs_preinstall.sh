#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR
# LOCAL_REGISTRY_HOST

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function template_rke2_configs_preinstall() {
    log_info "templating rke2 confings before install";
    mkdir -p "$OUTPUTDIR/etc/rancher/rke2";
    NODENAME="$(cat "$OUTPUTDIR/etc/hostname")" \
        envsubst \
            '$LOCAL_REGISTRY_HOST,$NODE_NAME' \
        < "$BUILDROOT/files/configs/etc/rancher/rke2/config.yaml.tmpl" \
        > "$OUTPUTDIR/etc/rancher/rke2/config.yaml";
    envsubst \
        '$LOCAL_REGISTRY_HOST' \
    < "$BUILDROOT/files/configs/etc/rancher/rke2/config.yaml.tmpl" \
    > "$OUTPUTDIR/etc/rancher/rke2/registries.yaml";
}

template_rke2_configs_preinstall;
