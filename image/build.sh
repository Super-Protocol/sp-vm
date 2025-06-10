#!/bin/bash

set -euo pipefail;

BOOT_PART="p1";
BIOS_PART="p2";
EFI_PART="p3";
ROOTFS_PART="p4";
ROOTFS_HASH_PART="p5";

# Create empty disk
qemu-img create -f raw test.raw 3G
IMG_PATH=$(realpath test.raw);

# Partitions etc
parted --script test.raw \
    mklabel gpt \
    mkpart bls_boot ext4 1MiB 1074MiB \
    set 1 bls_boot on \
    mkpart bios_grub 1075MiB 1079MiB \
    set 2 bios_grub on \
    mkpart ESP fat32 1079MiB 1190MiB \
    set 3 boot on \
    set 3 esp on \
    mkpart rootfs ext4 1190MiB 100%

# Mounting image
LOOP_DEV=$(losetup --find --show --partscan test.raw);
LOOP_DEV_NAME=$(tr -d "/dev" <<< "$LOOP_DEV");
kpartx -av "$LOOP_DEV";

function cleanup() {
    umount /mnt/boot/efi || true;
    umount /mnt/boot || true;
    for CUR in $(losetup -a | grep "($IMG_PATH)" | awk -F ':' '{print $1}'); do
        kpartx -d "$CUR" || true;
        losetup -d $CUR;
    done
}
trap cleanup EXIT;

# Creating fsss
mkfs.ext4 -L bls_boot /dev/mapper/${LOOP_DEV_NAME}${BOOT_PART};
mkfs.fat -F 32 /dev/mapper/${LOOP_DEV_NAME}${EFI_PART};
mkfs.ext4 -L rootfs /dev/mapper/${LOOP_DEV_NAME}${ROOTFS_PART};

# Mounting all shit
mkdir -p /mnt/boot;
mount /dev/mapper/${LOOP_DEV_NAME}${BOOT_PART} /mnt/boot;
mkdir -p /mnt/boot/efi;
mount /dev/mapper/${LOOP_DEV_NAME}${EFI_PART} /mnt/boot/efi;
mkdir -p /mnt/boot/efi/EFI/BOOT;

# Installing the GRUB
## UEFI
grub-install \
    --target=x86_64-efi \
    --efi-directory=/mnt/boot/efi \
    --boot-directory=/mnt/boot \
    --no-floppy \
    --modules="normal part_gpt part_msdos multiboot" \
    --no-nvram \
    --removable \
    --bootloader-id=GRUB \
    "$LOOP_DEV";

## BIOS
grub-install \
    --target i386-pc \
    --boot-directory=/mnt/boot \
    "$LOOP_DEV";

# Adding files
cp /files/vmlinuz /mnt/boot/
cp /files/grub.cfg /mnt/boot/grub/
