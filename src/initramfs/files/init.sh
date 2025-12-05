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

log_info "starting SP init";

rootfs_verifier="$(get_option rootfs_verity.scheme)";
rootfs_hash="$(get_option rootfs_verity.hash)";
root_device_name="$(get_option root)";

root_device="$(get_device "$root_device_name")";

# hash device can only be found by partition label (not fs label)
hash_device="$(blkid -t PARTLABEL="rootfs_hash" --output device || echo)";

provider_config_device="$(blkid -L provider_config --output device)";

# The root device should exist to be either verified then mounted or
# just mounted when verification is disabled.
if [ ! -e "${root_device}" ]; then
    log_fail "No root device ${root_device} found"
fi
if [ ! -e "${provider_config_device}" ]; then
    log_fail "No root device ${provider_config_device} found"
fi

if [ "${rootfs_verifier}" = "dm-verity" ]; then
    log_info "Verify the root device with ${rootfs_verifier}"

    if [ ! -e "${hash_device}" ]; then
        log_fail "No hash device ${hash_device} found. Cannot verify the root device"
    fi

    log_info "Verifying rootfs RO hash"
    veritysetup open "${root_device}" root "${hash_device}" "${rootfs_hash}"
    log_info "Mounting rootfs RO"
    mount /dev/mapper/root /sysroot-ro
else
    log_warn "Skipping rootfs RO hash check"
    log_info "Mounting rootfs RO"
    mount "${root_device}" /sysroot-ro
fi

log_info "$(lsblk)";

main_block_device_name="$(lsblk -no PKNAME "$root_device" | grep -v "$(basename "$root_device")")";
if [ -z "$main_block_device_name" ]; then
    log_fail "Failed to get main block device name from data part device path '$root_device'..";
fi

state_block_device_name="$(lsblk -d -n -o NAME | grep -v "$main_block_device_name" | grep -v "$(basename "$provider_config_device")")";
if [ -z "$state_block_device_name" ]; then
    log_fail "Failed to get state block device, this error is abnomal and you should notify the SuperProtocol support team if you see this.."
fi
state_block_device_path="/dev/$state_block_device_name";

echo -e "TRACE: root_device = $root_device\n" > /dev/console
echo -e "TRACE: provider_config_device = $provider_config_device\n" > /dev/console
echo -e "TRACE: state_block_device_path = $state_block_device_path\n" > /dev/console

# Mounting encrypted state disk
random_key="$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64)";
echo -e "TRACE: wipefs -a \$state_block_device_path output:" > /dev/console
wipefs -a "$state_block_device_path" >/dev/console 2>&1 || true;
echo -e "\nTRACE: cryptsetup luksFormat \$state_block_device_path output:" > /dev/console
echo "\$random_key" | cryptsetup luksFormat "$state_block_device_path" --batch-mode >/dev/console 2>&1
echo -e "\nTRACE: cryptsetup luksOpen \$state_block_device_path output:" > /dev/console
echo "\$random_key" | cryptsetup luksOpen "$state_block_device_path" crypto >/dev/console 2>&1
echo -e "\nTRACE: mkfs.ext4 /dev/mapper/crypto output:" > /dev/console
mkfs.ext4 /dev/mapper/crypto >/dev/console 2>&1
echo -e "\nTRACE: mount /dev/mapper/crypto /sysroot-rw output:" > /dev/console
mount /dev/mapper/crypto /sysroot-rw >/dev/console 2>&1

[ -d /sysroot-rw/upper ] || mkdir /sysroot-rw/upper
[ -d /sysroot-rw/work ] || mkdir /sysroot-rw/work

echo -e "\nTRACE: mount overlay output:" > /dev/console
mount -t overlay overlay \
  -o lowerdir=/sysroot-ro,upperdir=/sysroot-rw/upper,workdir=/sysroot-rw/work \
  /mnt >/dev/console 2>&1

umount /proc
umount /sys
exec switch_root /mnt /sbin/init
