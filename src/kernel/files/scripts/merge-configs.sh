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
        -r -n -y $CONFIGS_FRAGMENTS \
        | grep 'not in final' \
        | grep -v -f "$CONFIGS_CHECK_SKIPLIST" || true);

    if [[ -n "$OUTPUT" ]]; then
        log_fail "failed to merge kernel configs, reason: $OUTPUT"
    fi

    # allnoconfig + CONFIG_MODULES=y often leaves Hyper-V as =m. Initramfs is
    # packed before modules_install, so =m means Azure never sees disks/NIC.
    # Linux 6.12: HYPERV_STORAGE cannot be builtin if SCSI_FC_ATTRS=m
    # (depends on m || SCSI_FC_ATTRS != m). Disable unused FC attrs so
    # olddefconfig is allowed to keep STORAGE=y.
    ./scripts/config --file "$KCONFIG_CONFIG" \
        --enable HYPERVISOR_GUEST \
        --enable X86_LOCAL_APIC \
        --enable ACPI \
        --enable SCSI \
        --enable SCSI_LOWLEVEL \
        --enable CONNECTOR \
        --enable NLS \
        --disable SCSI_FC_ATTRS \
        --enable HYPERV \
        --enable HYPERV_STORAGE \
        --enable HYPERV_NET \
        --enable PCI_HYPERV \
        --enable NET_VENDOR_MICROSOFT \
        --enable MICROSOFT_MANA
    make "ARCH=$ARCH" olddefconfig
    ./scripts/config --file "$KCONFIG_CONFIG" \
        --disable SCSI_FC_ATTRS \
        --set-val HYPERV y \
        --set-val HYPERV_STORAGE y \
        --set-val HYPERV_NET y \
        --set-val PCI_HYPERV y
    make "ARCH=$ARCH" olddefconfig
    ./scripts/config --file "$KCONFIG_CONFIG" \
        --disable SCSI_FC_ATTRS \
        --set-val HYPERV y \
        --set-val HYPERV_STORAGE y \
        --set-val HYPERV_NET y

    if ! grep -qx 'CONFIG_HYPERV=y' "$KCONFIG_CONFIG"; then
        log_fail "CONFIG_HYPERV must be builtin (=y), got: $(grep '^CONFIG_HYPERV' "$KCONFIG_CONFIG" || echo unset)"
    fi
    if ! grep -qx 'CONFIG_HYPERV_STORAGE=y' "$KCONFIG_CONFIG"; then
        log_fail "CONFIG_HYPERV_STORAGE must be builtin (=y), got: $(grep '^CONFIG_HYPERV_STORAGE' "$KCONFIG_CONFIG" || echo unset)"
    fi
    if ! grep -qx 'CONFIG_HYPERV_NET=y' "$KCONFIG_CONFIG"; then
        log_fail "CONFIG_HYPERV_NET must be builtin (=y), got: $(grep '^CONFIG_HYPERV_NET' "$KCONFIG_CONFIG" || echo unset)"
    fi
    popd;
}

merge_configs;
