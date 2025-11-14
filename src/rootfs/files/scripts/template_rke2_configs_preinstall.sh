#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR
# LOCAL_REGISTRY_HOST
# SUPER_REGISTRY_HOST

# private
BUILDROOT="/buildroot";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function check_args() {
    if [[ -z "${LOCAL_REGISTRY_HOST:-""}" ]]; then
        log_fail "LOCAL_REGISTRY_HOST is required";
    fi
    if [[ -z "${SUPER_REGISTRY_HOST:-""}" ]]; then
        log_fail "SUPER_REGISTRY_HOST is required";
    fi
}

function template_rke2_configs_preinstall() {
    log_info "templating rke2 configs before install";
    mkdir -p "$OUTPUTDIR/etc/rancher/rke2";
    mkdir -p "$OUTPUTDIR/etc/super/etc/rancher/rke2";
    NODENAME="$(cat "$OUTPUTDIR/etc/hostname")" \
        envsubst \
            '$LOCAL_REGISTRY_HOST,$NODENAME' \
        < "$BUILDROOT/files/configs/etc/rancher/rke2/config.yaml.tmpl" \
        > "$OUTPUTDIR/etc/rancher/rke2/config.yaml";
    cp -a "$OUTPUTDIR/etc/rancher/rke2/config.yaml" "$OUTPUTDIR/etc/super/etc/rancher/rke2/config.yaml";
    envsubst \
        '$SUPER_REGISTRY_HOST,$LOCAL_REGISTRY_HOST' \
    < "$BUILDROOT/files/configs/etc/rancher/rke2/registries.yaml.tmpl" \
    > "$OUTPUTDIR/etc/rancher/rke2/registries.yaml";
    cp -a "$OUTPUTDIR/etc/rancher/rke2/registries.yaml" "$OUTPUTDIR/etc/super/etc/rancher/rke2/registries.yaml";
}

check_args;
template_rke2_configs_preinstall;
