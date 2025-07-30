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

function template_rke2_configs_postinstall() {
    log_info "templating rke2 confings after install";
    mkdir -p "$OUTPUTDIR/etc/super/var/lib/rancher/rke2/agent/etc/containerd";
    envsubst \
        '$LOCAL_REGISTRY_HOST' \
    < "$BUILDROOT/files/configs/etc/super/var/lib/rancher/rke2/agent/etc/containerd.config.toml.tmpl.tmpl" \
    > "$OUTPUTDIR/etc/super/var/lib/rancher/rke2/agent/etc/containerd.config.toml.tmpl";
}

function append_to_files() {
    log_info "appending to confings after rke2 install";
    cat \
        "$BUILDROOT/files/configs/usr/local/lib/systemd/system/rke2-server.env.append" \
    >> "$OUTPUTDIR/usr/local/lib/systemd/system/rke2-server.env";
    cat \
        "$BUILDROOT/files/configs/etc/multipath.conf.append" \
    >> "$OUTPUTDIR/etc/multipath.conf";
    cat \
        "$BUILDROOT/files/configs/etc/sysctl.conf.append" \
    >> "$OUTPUTDIR/etc/sysctl.conf";
}

function finalize_rke2() {
    log_info "finalizing rke2 install";
    mkdir -p "$OUTPUTDIR/etc/kubernetes";
}

template_rke2_configs_postinstall;
append_to_files;
finalize_rke2;
