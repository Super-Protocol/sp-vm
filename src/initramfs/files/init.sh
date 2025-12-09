#!/bin/sh

set -x

[ -d /dev ] || mkdir -m 0755 /dev
[ -d /root ] || mkdir -m 0700 /root
[ -d /sys ] || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /mnt ] || mkdir /mnt
[ -d /tmp ] || mkdir /tmp
[ -d /sysroot-ro ] || mkdir /sysroot-ro
[ -d /sysroot-rw ] || mkdir /sysroot-rw
[ -d /run/cryptsetup ] || mkdir -p /run/cryptsetup

mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc -o nodev,noexec,nosuid proc /proc

echo "/sbin/mdev" > /proc/sys/kernel/hotplug
mdev -s

get_option() {
    value=" $(cat /proc/cmdline) "
    value="${value##* ${1}=}"
    value="${value%% *}"
    [ "${value}" != "" ] && echo "${value}"
}

# device can be specified by partition and fs labels, but we will use only partition label
get_device() {
    LABEL_NAME="${1#*=}"; # 'LABEL=rootfs' > 'rootfs
    blkid -t PARTLABEL="$LABEL_NAME" --output device || echo;
}

_log() {
    echo "$1: $0: $2" > /dev/console 2>&1
}

log_fail() {
    _log "FAIL" "$1";
    exit 1;
}
log_err() {
    _log "ERROR" "$1";
}
log_warn() {
    _log "WARNING" "$1";
}
log_info() {
    _log "INFO" "$1";
}

log_info "Starting SP init";

rootfs_verifier="$(get_option rootfs_verity.scheme)";
rootfs_hash="$(get_option rootfs_verity.hash)";
root_device_name="$(get_option root)";

root_device="$(get_device "$root_device_name")";

# hash device can only be found by partition label (not fs label)
hash_device_path="$(blkid -t PARTLABEL="rootfs_hash" --output device || echo)";

provider_config_device_path="$(blkid -L provider_config --output device || echo)";

# The root device should exist to be either verified then mounted or
# just mounted when verification is disabled.
if [ ! -e "${root_device}" ]; then
    log_fail "No root device ${root_device} found";
fi
if [ ! -e "${provider_config_device_path}" ]; then
    log_fail "No provider config device ${provider_config_device_path} found";
fi

if [ "${rootfs_verifier}" = "dm-verity" ]; then
    log_info "Verify the root device with ${rootfs_verifier}";

    if [ ! -e "${hash_device_path}" ]; then
        log_fail "No hash device ${hash_device_path} found. Cannot verify the root device";
    fi

    log_info "Verifying rootfs hash";
    veritysetup open "${root_device}" root "${hash_device_path}" "${rootfs_hash}" || log_fail "Verifying rootfs RO failed";
    log_info "Mounting rootfs RO";
    mount -o ro /dev/mapper/root /sysroot-ro || log_fail "Mounting rootfs RO failed";
else
    log_warn "Skipping rootfs RO hash check";
    log_info "Mounting rootfs RO";
    mount -o ro "${root_device}" /sysroot-ro || log_fail "Mounting rootfs RO failed";
fi

main_block_device_name="$(lsblk -no PKNAME "$root_device" | grep -v "$(basename "$root_device")")";
if [ -z "$main_block_device_name" ]; then
    log_fail "Failed to get main block device name from data part device path '$root_device'..";
fi

state_block_device_count="$(lsblk -d -n -o NAME | grep -v "$main_block_device_name" | grep -v "$(basename "$provider_config_device_path")" | wc -l)";

if [ "$state_block_device_count" -lt 1 ]; then
    log_fail "Failed to get state block device, please attach an extra disk to this VM";
fi
if [ "$state_block_device_count" -gt 1 ]; then
    log_fail "Found more than one state block device, please remove an extra block device and restart the VM";
fi

state_block_device_name="$(lsblk -d -n -o NAME | grep -v "$main_block_device_name" | grep -v "$(basename "$provider_config_device_path")")";
if [ -z "$state_block_device_name" ]; then
    log_fail "Failed to get state block device, this error is abnomal and you should notify the SuperProtocol support team if you see this..";
fi
state_block_device_path="/dev/$state_block_device_name";

random_key="$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64)";

log_info "Wiping filesystem signatures from the device $state_block_device_path";
wipefs -a "$state_block_device_path" || log_warn "Failed to wipe $state_block_device_path";

log_info "Formatting the device $state_block_device_path as LUKS encrypted";
echo "$random_key" | cryptsetup luksFormat "$state_block_device_path" --batch-mode || log_fail "Failed to format $state_block_device_path";

log_info "Opening the LUKS encrypted device $state_block_device_path";
echo "$random_key" | cryptsetup luksOpen "$state_block_device_path" crypto || log_fail "Failed to open";

log_info "Creating FS on /dev/mapper/crypto"
mkfs.ext4 /dev/mapper/crypto || log_fail "Failed to create ext4 filesystem on /dev/mapper/crypto";

log_info "Mounting encrypted state disk /dev/mapper/crypto";
mount /dev/mapper/crypto /sysroot-rw || log_fail "Mounting encrypted state disk failed";

[ -d /sysroot-rw/upper ] || mkdir /sysroot-rw/upper
[ -d /sysroot-rw/work ] || mkdir /sysroot-rw/work
[ -d /sysroot-rw/var ] || mkdir /sysroot-rw/var

log_info "Mounting overlay FS";
mount -t overlay overlay \
  -o lowerdir=/sysroot-ro,upperdir=/sysroot-rw/upper,workdir=/sysroot-rw/work \
  /mnt || log_fail "Mounting overlay FS failed";

[ -d /mnt/sp ] || mkdir /mnt/sp
log_info "Mounting provider config";
mount -t ext4 -o ro "$provider_config_device_path" /mnt/sp || log_fail "Mounting provider config failed";

# we can't do overlay over overlay, so, moving whole /var to upper-level fs
[ -d /mnt/var ] || mkdir /mnt/var
log_info "Mounting /var";
mount --bind /sysroot-rw/var /mnt/var || log_fail "Mounting /var failed";

log_info "Unmounting temp mounts";
umount /proc
umount /sys

log_info "Starting true real big great init! Bye..";
exec switch_root /mnt /sbin/init
