#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# KERNEL_VERSION

# private
BUILDROOT="/buildroot";
ARCH="$(uname -m)";
KERNEL_SRC="$BUILDROOT/src/linux-$KERNEL_VERSION";

# private, configs
ARCH_CONFIGS="$(ls $BUILDROOT/files/configs/fragments/$ARCH/*.conf)";
COMMON_CONFIGS="$(grep "\!${ARCH}" $BUILDROOT/files/configs/fragments/common/*.conf -L || true)"; # skip configs if they have !$arch tag in the header
GPU_CONFIGS="$BUILDROOT/files/configs/fragments/gpu/nvidia.x86_64.conf";
CRYPTSETUP_CONFIGS="$BUILDROOT/files/configs/fragments/common/confidential_containers/cryptsetup.conf";
INITRAMFS_CONFIGS="$BUILDROOT/files/configs/fragments/common/confidential_containers/initramfs.conf";
CONFIDENTIAL_CONFIGS=$(ls $BUILDROOT/files/configs/fragments/x86_64/confidential/*.conf);
TEMPFS_CONFIGS="$BUILDROOT/files/configs/fragments/common/confidential_containers/tmpfs.conf";
CONFIGS_FRAGMENTS="$COMMON_CONFIGS \
    $ARCH_CONFIGS \
    $GPU_CONFIGS \
    $CRYPTSETUP_CONFIGS \
    $INITRAMFS_CONFIGS \
    $CONFIDENTIAL_CONFIGS \
    $TEMPFS_CONFIGS";
CONFIGS_CHECK_SKIPLIST="$BUILDROOT/files/configs/fragments/whitelist.conf";

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function merge_configs() {
    export ARCH;
    export KCONFIG_CONFIG="$BUILDROOT/files/configs/fragments/$ARCH/.config"
    pushd "$KERNEL_SRC";
    log_info "staring config merge";

    OUTPUT=$("$BUILDROOT/files/scripts/merge_config.sh" \
        -r -n $CONFIGS_FRAGMENTS \
        | grep 'not in final' \
        | grep -v -f "$CONFIGS_CHECK_SKIPLIST" || true);

    if [[ -n "$OUTPUT" ]]; then
        log_fail "failed to merge kernel configs, reason: $OUTPUT"
    fi

    # Linux 6.12: HYPERV_STORAGE cannot be =y while SCSI_FC_ATTRS=m. Force
    # builtin Hyper-V after merge; do not olddefconfig after the last --set-val.
    ./scripts/config --file "$KCONFIG_CONFIG" \
        --disable SCSI_FC_ATTRS \
        --set-val HYPERV y \
        --set-val HYPERV_TIMER y \
        --set-val HYPERV_STORAGE y \
        --set-val HYPERV_NET y \
        --set-val PCI_HYPERV y \
        --set-val PCI_HYPERV_INTERFACE y \
        --enable NET_VENDOR_MICROSOFT \
        --set-val MICROSOFT_MANA y \
        --enable IP_PNP_DHCP
    make "ARCH=$ARCH" olddefconfig
    ./scripts/config --file "$KCONFIG_CONFIG" \
        --disable SCSI_FC_ATTRS \
        --set-val HYPERV y \
        --set-val HYPERV_TIMER y \
        --set-val HYPERV_STORAGE y \
        --set-val HYPERV_NET y \
        --set-val PCI_HYPERV y \
        --set-val PCI_HYPERV_INTERFACE y \
        --enable NET_VENDOR_MICROSOFT \
        --set-val MICROSOFT_MANA y \
        --enable IP_PNP_DHCP

    for sym in \
        CONFIG_HYPERV \
        CONFIG_HYPERV_TIMER \
        CONFIG_HYPERV_STORAGE \
        CONFIG_HYPERV_NET \
        CONFIG_PCI_HYPERV \
        CONFIG_PCI_HYPERV_INTERFACE \
        CONFIG_NET_VENDOR_MICROSOFT \
        CONFIG_MICROSOFT_MANA
    do
        if ! grep -qx "${sym}=y" "$KCONFIG_CONFIG"; then
            log_fail "${sym} must be builtin (=y), got: $(grep "^${sym}" "$KCONFIG_CONFIG" || echo unset)"
        fi
    done
    popd;
}

merge_configs;
