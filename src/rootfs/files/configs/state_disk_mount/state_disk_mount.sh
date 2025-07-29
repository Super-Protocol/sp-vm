#!/bin/bash

set -euo pipefail;

# Looking for state disk block device:
# 1. Get main system disk device name, e.g. 'vda', from veritysetup
# 2. Find other block devices
# 3.1. If their count > 1 - fail, this is abnormal, other disks is present
# 3.2. If their count < 1 - fail, this is abnormal, no state disk is present
# 3.3. If only one - this block dev will be used as the state disk

DATA_PART_DEVICE_PATH="$(veritysetup status root | grep 'data device' | awk -F ': ' '{print $2}' || echo)";
if [[ -z "$DATA_PART_DEVICE_PATH" ]]; then
    echo "Failed to get data partition device path from 'veritysetup status'..";
    exit 1;
fi

MAIN_BLOCK_DEVICE_NAME="$(lsblk -no PKNAME "$DATA_PART_DEVICE_PATH" || echo)";
if [[ -z "$MAIN_BLOCK_DEVICE_NAME" ]]; then
    echo "Failed to get main block device name from data part device path '$DATA_PART_DEVICE_PATH'..";
    exit 1;
fi

NON_SYSTEM_BLOCK_DEVICES_COUNT="$(lsblk -d -n -o NAME | { grep -v "$MAIN_BLOCK_DEVICE_NAME" || true; } | wc -l)";
if (( NON_SYSTEM_BLOCK_DEVICES_COUNT < 1 )); then
    echo "Only system disk is attached to this VM, please attach another block device for storing encrypted VM state and restart the VM";
    exit 1;
fi
if (( NON_SYSTEM_BLOCK_DEVICES_COUNT > 1 )); then
    echo "Found more than one non-system block device, there is no way to detect wich disk we should use for storing encrypted VM state, please remove an extra block device and restart the VM";
    exit 1;
fi

STATE_BLOCK_DEVICE_NAME="$(lsblk -d -n -o NAME | grep -v "$MAIN_BLOCK_DEVICE_NAME")";
if [[ -z "$STATE_BLOCK_DEVICE_NAME" ]]; then
    echo "Failed to get state block device, this error is abnomal and you should notify the SuperProtocol support team if you see this.."
    exit 1;
fi
STATE_BLOCK_DEVICE_PATH="/dev/$STATE_BLOCK_DEVICE_NAME";

RANDOM_KEY="$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64)";

wipefs -a "$STATE_BLOCK_DEVICE_PATH" || true;

echo "\$RANDOM_KEY" | cryptsetup luksFormat "$STATE_BLOCK_DEVICE_PATH" --batch-mode;
echo "\$RANDOM_KEY" | cryptsetup luksOpen "$STATE_BLOCK_DEVICE_PATH" crypto;

mkfs.ext4 "/dev/mapper/crypto";
