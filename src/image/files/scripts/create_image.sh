#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTROOT
# OUTPUTDIR
# IMAGESIZE
# VERSION

# private const
BUILDROOT="/buildroot";
OUTPUT_FILENAME="sp_$VERSION.img";
OUTPUT_FILE="$OUTPUTROOT/$OUTPUT_FILENAME";
BOOT_PART="p1";
BOOT_PART_SIZE="100";  # MiB
BIOS_PART="p2";
BIOS_PART_SIZE="4";  # MiB
ESP_PART="p3";
ESP_PART_SIZE="10";  # MiB
ROOTFS_PART="p4";
# ROOTFS_PART_SIZE will be calculated later
ROOTFS_HASH_PART="p5";
# ROOTFS_HASH_PART_SIZE will be calculated later

# private vars, unset
# LOOP_DEV
# LOOP_DEV_NAME
# ROOTFS_PART_SIZE
# ROOTFS_HASH_PART_SIZE
# IMAGESIZE

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

function calculate_disk_size() {
    log_info "determinating image part size";
    # adding extra 6% for ext4 meta
    ROOTFS_PART_SIZE="$(du -sm "$OUTPUTDIR" | awk '{print int($1 * 1.06)}')";  # MiB
    # hash part size will be ROOTFS_PART_SIZE * 0.99%
    ROOTFS_HASH_PART_SIZE="$(echo "$ROOTFS_PART_SIZE" | awk '{x = $1 * 0.0099; print (x == int(x)) ? x : int(x)+1}' )";
    # adding extra bytes for filling
    IMAGESIZE="$(( BOOT_PART_SIZE + BIOS_PART_SIZE + ESP_PART_SIZE + ROOTFS_PART_SIZE + ROOTFS_HASH_PART_SIZE + 10))";
    log_info "total image size will be: $IMAGESIZE MiB";
}

function create_empty_disk() {
    log_info "creating empty disk";
    qemu-img create -f raw "$OUTPUT_FILE" "${IMAGESIZE}M";
}

# Partitions etc
function create_partitions() {
    log_info "creating partitions";
    local BOOT_START="1";
    local BOOT_END="$(( BOOT_START + BOOT_PART_SIZE ))";
    local BIOS_PART_START="$BOOT_END";
    local BIOS_PART_END="$(( BIOS_PART_START + BIOS_PART_SIZE ))";
    local ESP_PART_START="$BIOS_PART_END";
    local ESP_PART_END="$(( ESP_PART_START + ESP_PART_SIZE ))";
    local ROOTFS_PART_START="$ESP_PART_END";
    local ROOTFS_PART_END="$(( ROOTFS_PART_START + ROOTFS_PART_SIZE ))";
    local ROOTFS_HASH_PART_START="$ROOTFS_PART_END";
    local ROOTFS_HASH_PART_END="$(( ROOTFS_HASH_PART_START + ROOTFS_HASH_PART_SIZE ))";

    parted --script "$OUTPUT_FILE" \
        mklabel gpt \
        mkpart bls_boot ext4 "${BOOT_START}MiB" "${BOOT_END}MiB" \
        set 1 bls_boot on \
        mkpart bios_grub "${BIOS_PART_START}MiB" "${BIOS_PART_END}MiB" \
        set 2 bios_grub on \
        mkpart ESP fat32 "${ESP_PART_START}MiB" "${ESP_PART_END}MiB" \
        set 3 boot on \
        set 3 esp on \
        mkpart rootfs ext4 "${ROOTFS_PART_START}MiB" "${ROOTFS_PART_END}MiB" \
        mkpart rootfs_hash "${ROOTFS_HASH_PART_START}MiB" "${ROOTFS_HASH_PART_END}MiB";
}

# Mounting image
function mount_image() {
    log_info "mounting image";
    LOOP_DEV=$(losetup --find --show --partscan "$OUTPUT_FILE");
    LOOP_DEV_NAME=$(tr -d "/dev" <<< "$LOOP_DEV");
    kpartx -av "$LOOP_DEV";
}

function cleanup() {
    log_info "umounting image";
    for CUR in $(losetup -a | grep "($OUTPUT_FILE)" | awk -F ':' '{print $1}'); do
        kpartx -d "$CUR" || true;
        losetup -d $CUR || true;
    done
}
trap cleanup EXIT;

# Creating fsss
function create_filesystems() {
    log_info "creating filesystems";
    mkfs.ext4 \
        -O ^has_journal,^huge_file,^meta_bg,^ext_attr \
        -L bls_boot \
        "/dev/mapper/${LOOP_DEV_NAME}${BOOT_PART}";
    mkfs.fat -F 32 "/dev/mapper/${LOOP_DEV_NAME}${ESP_PART}";
    mkfs.ext4 -m 0 \
        -O ^has_journal,^huge_file,^meta_bg,^ext_attr \
        -L rootfs \
        "/dev/mapper/${LOOP_DEV_NAME}${ROOTFS_PART}";
}

# Mounting all shit
function mount_partitions() {
    log_info "mounting partitions";
    mkdir -p "/mnt/boot";
    mount "/dev/mapper/${LOOP_DEV_NAME}${BOOT_PART}" "/mnt/boot";
    mkdir -p "/mnt/boot/efi";
    mount "/dev/mapper/${LOOP_DEV_NAME}${ESP_PART}" "/mnt/boot/efi";
    mkdir -p "/mnt/boot/efi/EFI/BOOT";
    mkdir -p "/mnt/rootfs";
    mount "/dev/mapper/${LOOP_DEV_NAME}${ROOTFS_PART}" "/mnt/rootfs";
}

function umount_boot_partitions() {
    log_info "umounting boot partitions";
    umount "/mnt/boot/efi";
    umount "/mnt/boot";
}

function umount_rootfs() {
    log_info "umounting rootfs";
    umount "/mnt/rootfs";
}

# Installing the GRUB
## UEFI
function install_grub_efi() {
    log_info "installing EFI grub";
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
}

## BIOS
function install_grub_bios() {
    log_info "installing BIOS grub";
    grub-install \
        --target i386-pc \
        --boot-directory=/mnt/boot \
        "$LOOP_DEV";
}

function copy_rootfs() {
    log_info "copying rootfs";
    cp -a "$OUTPUTDIR/." "/mnt/rootfs";
}

function move_boot_data() {
    log_info "moving boot data to boot partition";
    mv /mnt/rootfs/boot/* "/mnt/boot/";
}

function calc_rootfs_hash() {
    log_info "calculating rootfs hash";
    veritysetup \
        format \
        "/dev/mapper/${LOOP_DEV_NAME}${ROOTFS_PART}" \
        "/dev/mapper/${LOOP_DEV_NAME}${ROOTFS_HASH_PART}" \
        > "/tmp/rootfs_hash.txt";
}

function template_grub_config() {
    log_info "templating grub config";
    ROOTFS_HASH="$(grep 'Root hash' "/tmp/rootfs_hash.txt" | awk '{print $3}')";
    ROOTFS_HASH="$ROOTFS_HASH" \
        VERSION="$VERSION" \
        KERNEL_VERSION="$KERNEL_VERSION" \
        envsubst \
        '$ROOTFS_HASH,$VERSION,$KERNEL_VERSION' \
        > "/mnt/boot/grub/grub.cfg" \
        < "$BUILDROOT/files/configs/grub.cfg.tmpl";
}

function cleanup_rootfs_partition() {
    log_info "cleaning up rootfs partition";
    rm -rf "/mnt/rootfs/lost+found";
}

function cleanup_boot_partition() {
    log_info "cleaning up boot partition";
    rm -rf "/mnt/boot/lost+found";
}

calculate_disk_size;
create_empty_disk;
create_partitions;
mount_image;
create_filesystems;
mount_partitions;
install_grub_efi;
install_grub_bios;
copy_rootfs;
move_boot_data;
cleanup_rootfs_partition;
umount_rootfs;
calc_rootfs_hash;
template_grub_config;
cleanup_boot_partition;
umount_boot_partitions;
