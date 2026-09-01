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

    # allnoconfig often drops CONFIG_HYPERV=y even when the fragment requests it.
    # Re-enable after merge, then olddefconfig to pull in dependencies (SCSI_FC_ATTRS, etc.).
    ./scripts/config --file "$KCONFIG_CONFIG" \
        --enable SCSI_FC_ATTRS \
        --enable CONNECTOR \
        --enable HYPERV \
        --enable HYPERV_STORAGE \
        --enable HYPERV_NET \
        --enable PCI_HYPERV \
        --enable NET_VENDOR_MICROSOFT \
        --enable MICROSOFT_MANA
    make "ARCH=$ARCH" olddefconfig

    if ! grep -qx 'CONFIG_HYPERV=y' "$KCONFIG_CONFIG"; then
        log_fail "CONFIG_HYPERV=y missing after merge+olddefconfig (see x86_64/hyperv.conf)"
    fi
    if ! grep -qx 'CONFIG_HYPERV_STORAGE=y' "$KCONFIG_CONFIG"; then
        log_fail "CONFIG_HYPERV_STORAGE=y missing after merge (needs CONFIG_SCSI_FC_ATTRS=y)"
    fi
    if ! grep -qx 'CONFIG_HYPERV_NET=y' "$KCONFIG_CONFIG"; then
        log_fail "CONFIG_HYPERV_NET=y missing after merge"
    fi
    popd;
}

merge_configs;
