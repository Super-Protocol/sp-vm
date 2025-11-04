#!/bin/bash

set -euo pipefail;

# Looking for state and provider disk block device:
# 1. Get main system disk device name, e.g. 'vda', from veritysetup, their count can't be > 1
# 2. Get provider config block device from ext4 label 'provider_config'
# 2.1. If their count > 1 - fail, this is abnormal, other disks is present
# 2.2. If their count < 1 - fail, this is abnormal, no provider disk is present
# 2.3. If only one - this block dev will be used as the provider disk
# 3. Find other block devices
# 4.1. If their count > 1 - fail, this is abnormal, other disks is present
# 4.2. If their count < 1 - fail, this is abnormal, no state disk is present
# 4.3. If only one - this block dev will be used as the state disk

DATA_PART_DEVICE_PATH="$({ veritysetup status root | grep 'data device' | awk -F ': ' '{print $2}'; } || echo)";
if [[ -z "$DATA_PART_DEVICE_PATH" ]]; then
    echo "Failed to get data partition device path from 'veritysetup status'..";
    exit 1;
fi

MAIN_BLOCK_DEVICE_NAME="$(lsblk -no PKNAME "$DATA_PART_DEVICE_PATH" || echo)";
if [[ -z "$MAIN_BLOCK_DEVICE_NAME" ]]; then
    echo "Failed to get main block device name from data part device path '$DATA_PART_DEVICE_PATH'..";
    exit 1;
fi

PROVIDER_CONFIG_DEVICE_COUNT="$({ blkid -L provider_config --output device || true; } | wc -l)";
if (( PROVIDER_CONFIG_DEVICE_COUNT < 1 )); then
    echo "Failed to get provider config device, please attach an extra disk to this VM, it must be ext4-formatted drive with FS label 'provider_config'";
    exit 1;
fi
if (( PROVIDER_CONFIG_DEVICE_COUNT > 1 )); then
    echo "Found more than one ext4-formatted drive with FS label 'provider_config', there is no way to detect wich disk we should use for loading provider config, please remove an extra block device and restart the VM";
    exit 1;
fi

PROVIDER_CONFIG_DEVICE_PATH="$(blkid -L provider_config --output device || echo)";
if [[ -z "$PROVIDER_CONFIG_DEVICE_PATH" ]]; then
    echo "Failed to get provider config device, this error is abnomal and you should notify the SuperProtocol support team if you see this..";
    exit 1;
fi
PROVIDER_CONFIG_BLOCK_DEVICE_NAME="$(basename "$PROVIDER_CONFIG_DEVICE_PATH" || echo)";
if [[ -z "$PROVIDER_CONFIG_BLOCK_DEVICE_NAME" ]]; then
    echo "Failed to get provider config block device name from device path '$PROVIDER_CONFIG_DEVICE_PATH'..";
    exit 1;
fi

NON_SYSTEM_BLOCK_DEVICES_COUNT="$(lsblk -d -n -o NAME | { grep -v "$MAIN_BLOCK_DEVICE_NAME" || true; } | { grep -v "$PROVIDER_CONFIG_BLOCK_DEVICE_NAME" || true; } | wc -l)";
if (( NON_SYSTEM_BLOCK_DEVICES_COUNT < 1 )); then
    echo "Only system disk is attached to this VM, please attach another block device for storing encrypted VM state and restart the VM";
    exit 1;
fi
if (( NON_SYSTEM_BLOCK_DEVICES_COUNT > 1 )); then
    echo "Found more than one non-system block device, there is no way to detect wich disk we should use for storing encrypted VM state, please remove an extra block device and restart the VM";
    exit 1;
fi

STATE_BLOCK_DEVICE_NAME="$(lsblk -d -n -o NAME | grep -v "$MAIN_BLOCK_DEVICE_NAME" | grep -v "$PROVIDER_CONFIG_BLOCK_DEVICE_NAME")";
if [[ -z "$STATE_BLOCK_DEVICE_NAME" ]]; then
    echo "Failed to get state block device, this error is abnomal and you should notify the SuperProtocol support team if you see this.."
    exit 1;
fi

# Mounting encrypted state disk
STATE_BLOCK_DEVICE_PATH="/dev/$STATE_BLOCK_DEVICE_NAME";
RANDOM_KEY="$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64)";
wipefs -a "$STATE_BLOCK_DEVICE_PATH" || true;
echo "\$RANDOM_KEY" | cryptsetup luksFormat "$STATE_BLOCK_DEVICE_PATH" --batch-mode;
echo "\$RANDOM_KEY" | cryptsetup luksOpen "$STATE_BLOCK_DEVICE_PATH" crypto;
mkfs.ext4 "/dev/mapper/crypto";

# Mount encrypted state filesystem to /run/state and prepare subdirs for bind mounts
mkdir -p /run/state
mount -t ext4 "/dev/mapper/crypto" /run/state
for d in \
  /run/state/var \
  /run/state/kubernetes \
  /run/state/opt \
  /run/state/etciscsi
do
  mkdir -p "$d"
done

# Mounting read-only provider config
mount -t ext4 -o ro "$PROVIDER_CONFIG_DEVICE_PATH" /sp || { echo "failed to mount $PROVIDER_CONFIG_DEVICE_PATH to /sp"; exit 1; };
