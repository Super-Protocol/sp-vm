#!/bin/sh

set -x

BUSYBOX=/sbin/busybox

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

path_basename() {
    "$BUSYBOX" basename "$1";
}

read_sysfs_attr() {
    local value="";
    if [ -r "$1" ]; then
        IFS= read -r value < "$1" || true;
    fi
    echo "$value";
}

canonical_path() {
    if [ -e "$1" ]; then
        "$BUSYBOX" readlink -f "$1" 2>/dev/null || true;
    fi
}

device_top_level_name() {
    local device_name parent_name;
    device_name="$(path_basename "$1")";

    if [ -e "/sys/class/block/${device_name}/partition" ]; then
        parent_name="$(path_basename "$(canonical_path "/sys/class/block/${device_name}/..")")";
        if [ -n "$parent_name" ]; then
            echo "$parent_name";
            return 0;
        fi
    fi

    parent_name="$(lsblk -no PKNAME "$1" 2>/dev/null || true)";
    if [ -n "$parent_name" ]; then
        echo "$parent_name";
    else
        echo "$device_name";
    fi
}

resolve_google_disk_symlink() {
    local disk_name="$1" symlink resolved target_name;
    for symlink in /dev/disk/by-id/google-*; do
        [ -e "$symlink" ] || continue;
        case "$symlink" in
            *-part*) continue ;;
            *google-local-ssd-*|*google-local-nvme-ssd-*) continue ;;
        esac
        resolved="$(canonical_path "$symlink")";
        [ -n "$resolved" ] || continue;
        target_name="$(path_basename "$resolved")";
        if [ "$target_name" = "$disk_name" ]; then
            echo "$symlink";
            return 0;
        fi
    done
    return 1;
}

resolve_google_local_ssd_symlink() {
    local disk_name="$1" symlink resolved target_name;
    for symlink in /dev/disk/by-id/google-local-ssd-* /dev/disk/by-id/google-local-nvme-ssd-*; do
        [ -e "$symlink" ] || continue;
        case "$symlink" in
            *-part*) continue ;;
        esac
        resolved="$(canonical_path "$symlink")";
        [ -n "$resolved" ] || continue;
        target_name="$(path_basename "$resolved")";
        if [ "$target_name" = "$disk_name" ]; then
            echo "$symlink";
            return 0;
        fi
    done
    return 1;
}

list_state_disk_candidates() {
    local disk_name provider_block_device_name="";
    if [ -n "${provider_config_device_path:-}" ]; then
        provider_block_device_name="$(device_top_level_name "$provider_config_device_path")";
    fi

    for disk_name in $(lsblk -d -n -o NAME); do
        case "$disk_name" in
            loop*|ram*|dm-*) continue ;;
        esac
        if [ "$disk_name" = "$main_block_device_name" ]; then
            continue;
        fi
        if [ -n "$provider_block_device_name" ] && [ "$disk_name" = "$provider_block_device_name" ]; then
            continue;
        fi
        echo "$disk_name";
    done
}

log_disk_candidate() {
    local disk_name="$1" model vendor serial size_bytes pd_link local_link;
    model="$(read_sysfs_attr "/sys/block/$disk_name/device/model")";
    vendor="$(read_sysfs_attr "/sys/block/$disk_name/device/vendor")";
    serial="$(read_sysfs_attr "/sys/block/$disk_name/device/serial")";
    size_bytes="$(lsblk -d -n -b -o SIZE "/dev/$disk_name" 2>/dev/null || echo "?")";
    pd_link="$(resolve_google_disk_symlink "$disk_name" || true)";
    local_link="$(resolve_google_local_ssd_symlink "$disk_name" || true)";
    log_info "State disk candidate /dev/${disk_name}: size_bytes=${size_bytes} vendor='${vendor}' model='${model}' serial='${serial}' pd_link='${pd_link}' local_ssd_link='${local_link}'";
}

select_state_disk_path() {
    local candidate_names="" disk_name model vendor pd_link local_link;
    local candidate_count=0 pd_link_count=0 pd_model_count=0;
    local pd_link_path="" pd_model_path="" only_candidate_path="";

    for disk_name in $(list_state_disk_candidates); do
        candidate_count=$((candidate_count + 1));
        candidate_names="${candidate_names} ${disk_name}";
        only_candidate_path="/dev/${disk_name}";
        log_disk_candidate "$disk_name";

        pd_link="$(resolve_google_disk_symlink "$disk_name" || true)";
        if [ -n "$pd_link" ]; then
            pd_link_count=$((pd_link_count + 1));
            pd_link_path="/dev/${disk_name}";
        fi

        local_link="$(resolve_google_local_ssd_symlink "$disk_name" || true)";
        model="$(read_sysfs_attr "/sys/block/$disk_name/device/model")";
        vendor="$(read_sysfs_attr "/sys/block/$disk_name/device/vendor")";
        case "${vendor} ${model} ${local_link}" in
            *nvme_card-pd*|*PersistentDisk*|*Hyperdisk*)
                if [ -z "$local_link" ]; then
                    pd_model_count=$((pd_model_count + 1));
                    pd_model_path="/dev/${disk_name}";
                fi
                ;;
        esac
    done

    if [ "$candidate_count" -lt 1 ]; then
        log_fail "Failed to get state block device, please attach an extra disk to this VM";
    fi

    if [ "$pd_link_count" -eq 1 ]; then
        log_info "Selected state disk by Google persistent-disk symlink: ${pd_link_path}";
        state_block_device_path="$pd_link_path";
        return 0;
    fi

    if [ "$pd_model_count" -eq 1 ]; then
        log_info "Selected state disk by sysfs model/vendor heuristic: ${pd_model_path}";
        state_block_device_path="$pd_model_path";
        return 0;
    fi

    if [ "$candidate_count" -eq 1 ]; then
        log_warn "Falling back to the only extra block device as state disk: ${only_candidate_path}";
        state_block_device_path="$only_candidate_path";
        return 0;
    fi

    log_fail "Found multiple extra block devices (${candidate_names# }); unable to determine a unique state disk";
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
if [ -e "${provider_config_device_path}" ]; then
    log_info "Found provider config device at ${provider_config_device_path} (on-premise mode)";
else
    log_info "No provider config device found, /sp will be mounted via s3fs after boot (cloud mode)";
    provider_config_device_path="";
fi

# The root device should exist to be either verified then mounted or
# just mounted when verification is disabled.
if [ ! -e "${root_device}" ]; then
    log_fail "No root device ${root_device} found";
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

main_block_device_name="$(device_top_level_name "$root_device")";
if [ -z "$main_block_device_name" ]; then
    log_fail "Failed to get main block device name from data part device path '$root_device'..";
fi
log_info "Resolved root block device ${root_device} to top-level disk ${main_block_device_name}";

state_block_device_path="";
select_state_disk_path
if [ -z "$state_block_device_path" ]; then
    log_fail "Failed to resolve state block device path";
fi

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
if [ -n "$provider_config_device_path" ]; then
    log_info "Mounting provider config (on-premise mode)";
    mount -t ext4 -o ro "$provider_config_device_path" /mnt/sp || log_fail "Mounting provider config failed";
else
    log_info "No provider config device, /sp will be mounted via s3fs after boot (cloud mode)";
fi

# we can't do overlay over overlay, so, moving whole /var to upper-level fs
[ -d /mnt/var ] || mkdir /mnt/var
log_info "Mounting /var";
mount --bind /sysroot-rw/var /mnt/var || log_fail "Mounting /var failed";

log_info "Unmounting temp mounts";
umount /proc
umount /sys

log_info "Starting true real big great init! Bye..";
exec switch_root /mnt /sbin/init
