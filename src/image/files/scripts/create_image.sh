#!/usr/bin/env bash

set -euo pipefail

SP_VM_IMAGE_VERSION="${SP_VM_IMAGE_VERSION:-build-local}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1783987200}"

BUILDROOT="/buildroot"
OUTPUT_FILENAME="sp-vm-${SP_VM_IMAGE_VERSION}.img"
OUTPUT_FILE="$OUTPUTROOT/$OUTPUT_FILENAME"

MIB=$((1024 * 1024))
SECTORS_PER_MIB=2048
BOOT_START_MIB=1
BOOT_SIZE_MIB=100
BIOS_START_MIB=101
BIOS_SIZE_MIB=4
ESP_START_MIB=105
ESP_SIZE_MIB=100
ROOTFS_START_MIB=205
EXTRA_DISK_SIZE_MIB=10

BOOT_UUID="${BOOT_UUID:-53e6f641-37c0-46d2-a729-7d9f49fcf589}"
BOOT_DIR_HASH_SEED="${BOOT_DIR_HASH_SEED:-696833d7-b1d1-4f05-8ede-1a62f2e0a70d}"
ESP_VOLUME_ID="${ESP_VOLUME_ID:-A1B2C3D4}"
DISK_GUID="${DISK_GUID:-6f873c23-1b65-4b5c-8e67-8f4f3c3419a1}"
BOOT_PART_GUID="${BOOT_PART_GUID:-4389386d-d949-4b54-942d-3f6b1148c8d1}"
BIOS_PART_GUID="${BIOS_PART_GUID:-f4958893-2686-4bca-8251-1499197a2774}"
ESP_PART_GUID="${ESP_PART_GUID:-58f79298-702d-4a8b-b53c-73a76da19e77}"
ROOTFS_PART_GUID="${ROOTFS_PART_GUID:-ec6a4d3f-0f19-47df-9c1f-8f221bbf175b}"
ROOTFS_HASH_PART_GUID="${ROOTFS_HASH_PART_GUID:-672b89b6-76c3-45a5-af55-0a401f2d5a6f}"

WORK_DIR="$(mktemp -d -t sp-vm-image.XXXXXXXX)"
ROOTFS_ARTIFACT_DIR="$WORK_DIR/rootfs-verity"
ROOTFS_IMAGE="$ROOTFS_ARTIFACT_DIR/rootfs.ext4"
ROOTFS_VERITY_IMAGE="$ROOTFS_ARTIFACT_DIR/rootfs.verity"
BOOT_STAGE="$WORK_DIR/boot-stage"
ESP_STAGE="$WORK_DIR/esp-stage"
BOOT_IMAGE="$WORK_DIR/boot.ext4"
ESP_IMAGE="$WORK_DIR/esp.fat"
EARLY_GRUB_CONFIG="$WORK_DIR/early-grub.cfg"
BIOS_CORE_IMAGE="$WORK_DIR/core.img"
EFI_GRUB_IMAGE="$WORK_DIR/BOOTX64.EFI"
LOOP_DEV=""

# shellcheck disable=SC1091
source "$BUILDROOT/files/scripts/log.sh"

function cleanup() {
    local status=$?

    if mountpoint -q /mnt/boot; then
        umount /mnt/boot || true
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        kpartx -d "$LOOP_DEV" >/dev/null 2>&1 || true
        losetup --detach "$LOOP_DEV" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
    return "$status"
}
trap cleanup EXIT

function fail() {
    log_fail "$*"
    exit 1
}

function validate_inputs() {
    [[ -d "$OUTPUTDIR" ]] || fail "rootfs directory does not exist: $OUTPUTDIR"
    [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || fail "invalid SOURCE_DATE_EPOCH"
    [[ "$ESP_VOLUME_ID" =~ ^[0-9A-Fa-f]{8}$ ]] || fail "invalid ESP_VOLUME_ID"

    local uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    local value
    for value in \
        "$BOOT_UUID" "$BOOT_DIR_HASH_SEED" "$DISK_GUID" \
        "$BOOT_PART_GUID" "$BIOS_PART_GUID" "$ESP_PART_GUID" \
        "$ROOTFS_PART_GUID" "$ROOTFS_HASH_PART_GUID"; do
        [[ "$value" =~ $uuid_pattern ]] || fail "invalid UUID/GUID: $value"
    done
}

function detect_kernel() {
    mapfile -t kernels < <(
        find "$OUTPUTDIR/boot" \
            -maxdepth 1 \
            -type f \
            -name 'vmlinuz-*-nvidia-gpu-confidential' \
            -printf '%f\n' \
            | LC_ALL=C sort
    )

    if [[ "${#kernels[@]}" -ne 1 ]]; then
        fail "expected exactly one confidential kernel in $OUTPUTDIR/boot, found ${#kernels[@]}"
    fi
    KERNEL_FILENAME="${kernels[0]}"
    log_info "using kernel: $KERNEL_FILENAME"
}

function create_rootfs_verity() {
    log_info "creating deterministic rootfs ext4 and dm-verity blobs"
    "$BUILDROOT/files/scripts/create_rootfs_verity.sh" \
        "$OUTPUTDIR" \
        "$ROOTFS_ARTIFACT_DIR"

    local rootfs_bytes
    local rootfs_hash_bytes
    rootfs_bytes="$(stat --format='%s' "$ROOTFS_IMAGE")"
    rootfs_hash_bytes="$(stat --format='%s' "$ROOTFS_VERITY_IMAGE")"
    (( rootfs_bytes % MIB == 0 && rootfs_hash_bytes % MIB == 0 )) \
        || fail "rootfs blobs must be aligned to whole MiB"
    ROOTFS_SIZE_MIB="$((rootfs_bytes / MIB))"
    ROOTFS_HASH_SIZE_MIB="$((rootfs_hash_bytes / MIB))"
    ROOTFS_HASH_START_MIB="$((ROOTFS_START_MIB + ROOTFS_SIZE_MIB))"
    DISK_SIZE_MIB="$((ROOTFS_HASH_START_MIB + ROOTFS_HASH_SIZE_MIB + EXTRA_DISK_SIZE_MIB))"
}

function copy_tree() {
    local source_directory="$1"
    local target_directory="$2"

    mkdir -p "$target_directory"
    LC_ALL=C tar \
        --sort=name \
        --numeric-owner \
        --acls \
        --xattrs \
        --xattrs-include='*' \
        --selinux \
        --sparse \
        --directory="$source_directory" \
        --create \
        --file=- \
        . \
        | tar \
            --numeric-owner \
            --acls \
            --xattrs \
            --xattrs-include='*' \
            --selinux \
            --sparse \
            --directory="$target_directory" \
            --extract \
            --file=-
}

function create_grub_config() {
    mkdir -p "$BOOT_STAGE/grub"
    ROOTFS_HASH="$(cat "$ROOTFS_ARTIFACT_DIR/rootfs_hash.txt")"
    [[ "$ROOTFS_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "invalid rootfs hash"

    # shellcheck disable=SC2016
    ROOTFS_HASH="$ROOTFS_HASH" \
        SP_VM_IMAGE_VERSION="$SP_VM_IMAGE_VERSION" \
        KERNEL_FILENAME="$KERNEL_FILENAME" \
        envsubst \
        '$ROOTFS_HASH,$SP_VM_IMAGE_VERSION,$KERNEL_FILENAME' \
        < "$BUILDROOT/files/configs/grub.cfg.tmpl" \
        > "$BOOT_STAGE/grub/grub.cfg"

    cat > "$EARLY_GRUB_CONFIG" <<'EOF'
search --no-floppy --label bls_boot --set=root
set prefix=($root)/grub
configfile $prefix/grub.cfg
EOF
    grub-script-check "$EARLY_GRUB_CONFIG"
    grub-script-check "$BOOT_STAGE/grub/grub.cfg"
}

function create_grub_images() {
    log_info "creating deterministic standalone BIOS and UEFI GRUB images"
    local bios_modules='biosdisk part_gpt ext2 normal configfile search search_label linux'
    local efi_modules='part_gpt fat ext2 normal configfile search search_label linux'

    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" grub-mkstandalone \
        --format=i386-pc \
        --install-modules="$bios_modules" \
        --fonts='' \
        --locales='' \
        --themes='' \
        --output="$BIOS_CORE_IMAGE" \
        "boot/grub/grub.cfg=$EARLY_GRUB_CONFIG"

    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" grub-mkstandalone \
        --format=x86_64-efi \
        --install-modules="$efi_modules" \
        --fonts='' \
        --locales='' \
        --themes='' \
        --output="$EFI_GRUB_IMAGE" \
        "boot/grub/grub.cfg=$EARLY_GRUB_CONFIG"

    mkdir -p "$BOOT_STAGE/grub/bios" "$ESP_STAGE/EFI/BOOT"
    install -m 0644 /usr/lib/grub/i386-pc/boot.img "$BOOT_STAGE/grub/bios/boot.img"
    install -m 0644 "$BIOS_CORE_IMAGE" "$BOOT_STAGE/grub/bios/core.img"
    install -m 0644 "$EFI_GRUB_IMAGE" "$ESP_STAGE/EFI/BOOT/BOOTX64.EFI"
}

function append_inode_time_commands() {
    local commands_file="$1"
    local path="$2"

    path="${path//\"/\\\"}"
    {
        printf 'set_inode_field "%s" atime @%s\n' "$path" "$SOURCE_DATE_EPOCH"
        printf 'set_inode_field "%s" ctime @%s\n' "$path" "$SOURCE_DATE_EPOCH"
        printf 'set_inode_field "%s" mtime @%s\n' "$path" "$SOURCE_DATE_EPOCH"
        printf 'set_inode_field "%s" crtime @%s\n' "$path" "$SOURCE_DATE_EPOCH"
    } >> "$commands_file"
}

function normalize_ext4_inode_times() {
    local source_directory="$1"
    local image="$2"
    local commands_file="$WORK_DIR/boot-debugfs.commands"
    local relative_path

    : > "$commands_file"
    append_inode_time_commands "$commands_file" '/'
    while IFS= read -r -d '' relative_path; do
        [[ "$relative_path" != *$'\n'* && "$relative_path" != *$'\r'* ]] \
            || fail "boot path contains a newline"
        append_inode_time_commands "$commands_file" "/$relative_path"
    done < <(
        find "$source_directory" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z
    )

    LC_ALL=C TZ=UTC E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" debugfs \
        -w -f "$commands_file" "$image" >/dev/null 2>&1
}

function create_boot_image() {
    log_info "creating deterministic boot ext4 image"
    local object_count
    local inode_count
    object_count="$(find "$BOOT_STAGE" -printf '.' | wc -c)"
    inode_count=$((object_count + object_count / 10 + 128))

    truncate --size="$((BOOT_SIZE_MIB * MIB))" "$BOOT_IMAGE"
    LC_ALL=C TZ=UTC E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" mke2fs \
        -q -F -t ext4 \
        -b 4096 \
        -I 256 \
        -N "$inode_count" \
        -m 0 \
        -U "$BOOT_UUID" \
        -L bls_boot \
        -O '^has_journal,^huge_file,^meta_bg' \
        -E "hash_seed=${BOOT_DIR_HASH_SEED},lazy_itable_init=0,lazy_journal_init=0,nodiscard,root_owner=0:0" \
        -d "$BOOT_STAGE" \
        "$BOOT_IMAGE"
    LC_ALL=C TZ=UTC E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" debugfs \
        -w -R 'rmdir /lost+found' "$BOOT_IMAGE" >/dev/null 2>&1
    normalize_ext4_inode_times "$BOOT_STAGE" "$BOOT_IMAGE"
    e2fsck -fn "$BOOT_IMAGE"
}

function create_esp_image() {
    log_info "creating deterministic ESP FAT32 image"
    local fake_time
    fake_time="$(date --utc --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S')"

    truncate --size="$((ESP_SIZE_MIB * MIB))" "$ESP_IMAGE"
    mkfs.fat \
        --invariant \
        -F 32 \
        -i "$ESP_VOLUME_ID" \
        -n ESP \
        "$ESP_IMAGE" >/dev/null
    TZ=UTC faketime -f "@$fake_time" mcopy \
        -s \
        -i "$ESP_IMAGE" \
        "$ESP_STAGE"/* \
        ::/
    fsck.fat -vn "$ESP_IMAGE"
}

function create_partition_table() {
    log_info "creating deterministic GPT"
    local boot_start boot_end bios_start bios_end esp_start esp_end
    local rootfs_start rootfs_end rootfs_hash_start rootfs_hash_end

    boot_start=$((BOOT_START_MIB * SECTORS_PER_MIB))
    boot_end=$(((BOOT_START_MIB + BOOT_SIZE_MIB) * SECTORS_PER_MIB - 1))
    bios_start=$((BIOS_START_MIB * SECTORS_PER_MIB))
    bios_end=$(((BIOS_START_MIB + BIOS_SIZE_MIB) * SECTORS_PER_MIB - 1))
    esp_start=$((ESP_START_MIB * SECTORS_PER_MIB))
    esp_end=$(((ESP_START_MIB + ESP_SIZE_MIB) * SECTORS_PER_MIB - 1))
    rootfs_start=$((ROOTFS_START_MIB * SECTORS_PER_MIB))
    rootfs_end=$(((ROOTFS_START_MIB + ROOTFS_SIZE_MIB) * SECTORS_PER_MIB - 1))
    rootfs_hash_start=$((ROOTFS_HASH_START_MIB * SECTORS_PER_MIB))
    rootfs_hash_end=$(((ROOTFS_HASH_START_MIB + ROOTFS_HASH_SIZE_MIB) * SECTORS_PER_MIB - 1))

    truncate --size="$((DISK_SIZE_MIB * MIB))" "$OUTPUT_FILE"
    sgdisk \
        --clear \
        --set-alignment="$SECTORS_PER_MIB" \
        --disk-guid="$DISK_GUID" \
        --new="1:${boot_start}:${boot_end}" \
        --typecode=1:8300 \
        --change-name=1:bls_boot \
        --partition-guid="1:${BOOT_PART_GUID}" \
        --new="2:${bios_start}:${bios_end}" \
        --typecode=2:ef02 \
        --change-name=2:bios_grub \
        --partition-guid="2:${BIOS_PART_GUID}" \
        --new="3:${esp_start}:${esp_end}" \
        --typecode=3:ef00 \
        --change-name=3:ESP \
        --partition-guid="3:${ESP_PART_GUID}" \
        --new="4:${rootfs_start}:${rootfs_end}" \
        --typecode=4:8300 \
        --change-name=4:rootfs \
        --partition-guid="4:${ROOTFS_PART_GUID}" \
        --new="5:${rootfs_hash_start}:${rootfs_hash_end}" \
        --typecode=5:8300 \
        --change-name=5:rootfs_hash \
        --partition-guid="5:${ROOTFS_HASH_PART_GUID}" \
        "$OUTPUT_FILE" >/dev/null
    sgdisk --verify "$OUTPUT_FILE"
}

function write_partition_blob() {
    local blob="$1"
    local start_mib="$2"

    dd \
        if="$blob" \
        of="$OUTPUT_FILE" \
        bs=1M \
        seek="$start_mib" \
        conv=notrunc \
        status=none
}

function write_partition_blobs() {
    log_info "writing deterministic partition blobs"
    write_partition_blob "$BOOT_IMAGE" "$BOOT_START_MIB"
    write_partition_blob "$ESP_IMAGE" "$ESP_START_MIB"
    write_partition_blob "$ROOTFS_IMAGE" "$ROOTFS_START_MIB"
    write_partition_blob "$ROOTFS_VERITY_IMAGE" "$ROOTFS_HASH_START_MIB"
}

function install_bios_bootloader() {
    log_info "embedding deterministic BIOS GRUB core image"
    mkdir -p /mnt/boot
    LOOP_DEV="$(losetup --find --show --partscan "$OUTPUT_FILE")"
    local loop_name="${LOOP_DEV#/dev/}"
    kpartx -a "$LOOP_DEV" >/dev/null
    mount "/dev/mapper/${loop_name}p1" /mnt/boot
    /usr/lib/grub/i386-pc/grub-bios-setup \
        --skip-fs-probe \
        --directory=/mnt/boot/grub/bios \
        "$LOOP_DEV"
    umount /mnt/boot

    # Mounting changes ext4 superblock fields. Restore the canonical boot blob;
    # grub-bios-setup writes its boot code to the MBR and BIOS partition only.
    write_partition_blob "$BOOT_IMAGE" "$BOOT_START_MIB"
    kpartx -d "$LOOP_DEV" >/dev/null
    losetup --detach "$LOOP_DEV"
    LOOP_DEV=""
}

function verify_partition_blob() {
    local blob="$1"
    local start_mib="$2"
    local bytes
    local offset
    bytes="$(stat --format='%s' "$blob")"
    offset=$((start_mib * MIB))
    cmp \
        --bytes="$bytes" \
        --ignore-initial="0:$offset" \
        "$blob" \
        "$OUTPUT_FILE"
}

function verify_image() {
    log_info "verifying final disk layout and partition contents"
    sgdisk --verify "$OUTPUT_FILE"
    verify_partition_blob "$BOOT_IMAGE" "$BOOT_START_MIB"
    verify_partition_blob "$ESP_IMAGE" "$ESP_START_MIB"
    verify_partition_blob "$ROOTFS_IMAGE" "$ROOTFS_START_MIB"
    verify_partition_blob "$ROOTFS_VERITY_IMAGE" "$ROOTFS_HASH_START_MIB"

    cp "$ROOTFS_ARTIFACT_DIR/rootfs_hash.txt" "$OUTPUTROOT/rootfs_hash.txt"
}

validate_inputs
detect_kernel
create_rootfs_verity
copy_tree "$OUTPUTDIR/boot" "$BOOT_STAGE"
create_grub_config
create_grub_images
create_boot_image
create_esp_image
create_partition_table
write_partition_blobs
install_bios_bootloader
verify_image
