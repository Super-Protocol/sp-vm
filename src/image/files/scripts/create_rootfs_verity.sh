#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 ROOTFS_DIRECTORY OUTPUT_DIRECTORY" >&2
    exit 2
fi

SOURCE_ROOTFS="$1"
ARTIFACT_DIR="$2"

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1783987200}"
ROOTFS_UUID="${ROOTFS_UUID:-9d8ae77c-0f99-4b4c-a919-0de57b426ced}"
ROOTFS_DIR_HASH_SEED="${ROOTFS_DIR_HASH_SEED:-7ebf1975-28bf-544d-948f-5bb483eff52e}"
ROOTFS_VERITY_UUID="${ROOTFS_VERITY_UUID:-0ff7f592-c526-46f7-83d5-f47ad3f69e89}"
ROOTFS_VERITY_SALT="${ROOTFS_VERITY_SALT:-7ebf197528bf544d348f5bb483eff52ea41e0f99dac93882965f65924d1f87a6}"

BLOCK_SIZE=4096
MIB=$((1024 * 1024))
WORK_DIR="$(mktemp -d -t rootfs-verity.XXXXXXXX)"
STAGING_ROOTFS="$WORK_DIR/rootfs"

function cleanup() {
    local status=$?
    rm -rf "$WORK_DIR"
    return "$status"
}
trap cleanup EXIT

function fail() {
    echo "$*" >&2
    exit 1
}

function validate_inputs() {
    [[ -d "$SOURCE_ROOTFS" ]] || fail "Rootfs directory does not exist: $SOURCE_ROOTFS"
    [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] \
        || fail "SOURCE_DATE_EPOCH must be a non-negative integer"

    local uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    [[ "$ROOTFS_UUID" =~ $uuid_pattern ]] || fail "Invalid ROOTFS_UUID"
    [[ "$ROOTFS_DIR_HASH_SEED" =~ $uuid_pattern ]] || fail "Invalid ROOTFS_DIR_HASH_SEED"
    [[ "$ROOTFS_VERITY_UUID" =~ $uuid_pattern ]] || fail "Invalid ROOTFS_VERITY_UUID"
    [[ "$ROOTFS_VERITY_SALT" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid ROOTFS_VERITY_SALT"
}

function prepare_rootfs() {
    mkdir -p "$STAGING_ROOTFS"

    # /boot is stored on a separate partition. Keep the directory itself in
    # rootfs, but do not duplicate its contents in the verified filesystem.
    LC_ALL=C tar \
        --sort=name \
        --numeric-owner \
        --acls \
        --xattrs \
        --xattrs-include='*' \
        --selinux \
        --sparse \
        --one-file-system \
        --exclude='./boot/*' \
        --directory="$SOURCE_ROOTFS" \
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
            --directory="$STAGING_ROOTFS" \
            --extract \
            --file=-
}

function calculate_rootfs_size() {
    local content_bytes
    local object_count
    local required_bytes

    content_bytes="$(find "$STAGING_ROOTFS" -xdev -type f -printf '%s\n' \
        | awk '{total += $1} END {printf "%.0f", total}')"
    object_count="$(find "$STAGING_ROOTFS" -xdev -printf '.' | wc -c)"
    ROOTFS_INODE_COUNT=$((object_count + object_count / 10 + 1024))

    # File contents, 10% for ext4 allocation/metadata, one block per object,
    # and 64 MiB of fixed headroom. The result is rounded to whole MiB.
    required_bytes=$((
        content_bytes + content_bytes / 10 + object_count * BLOCK_SIZE + 64 * MIB
    ))
    ROOTFS_IMAGE_BYTES=$((((required_bytes + MIB - 1) / MIB) * MIB))
}

function create_ext4() {
    local rootfs_image="$ARTIFACT_DIR/rootfs.ext4"

    truncate --size="$ROOTFS_IMAGE_BYTES" "$rootfs_image"
    LC_ALL=C TZ=UTC E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" mke2fs \
        -q \
        -F \
        -t ext4 \
        -b "$BLOCK_SIZE" \
        -I 256 \
        -N "$ROOTFS_INODE_COUNT" \
        -m 0 \
        -U "$ROOTFS_UUID" \
        -L rootfs \
        -O '^has_journal,^huge_file,^meta_bg' \
        -E "hash_seed=${ROOTFS_DIR_HASH_SEED},lazy_itable_init=0,lazy_journal_init=0,nodiscard,root_owner=0:0" \
        -d "$STAGING_ROOTFS" \
        "$rootfs_image"

    # Preserve the previous rootfs layout: lost+found is not shipped.
    LC_ALL=C TZ=UTC E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" debugfs \
        -w \
        -R 'rmdir /lost+found' \
        "$rootfs_image" >/dev/null 2>&1

    normalize_inode_times "$rootfs_image"
    e2fsck -fn "$rootfs_image"
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

function normalize_inode_times() {
    local rootfs_image="$1"
    local commands_file="$WORK_DIR/debugfs.commands"
    local relative_path

    : > "$commands_file"
    append_inode_time_commands "$commands_file" '/'

    while IFS= read -r -d '' relative_path; do
        [[ -n "$relative_path" ]] || continue
        if [[ "$relative_path" == *$'\n'* || "$relative_path" == *$'\r'* ]]; then
            fail "Rootfs path contains a newline and cannot be passed safely to debugfs"
        fi
        append_inode_time_commands "$commands_file" "/$relative_path"
    done < <(
        find "$STAGING_ROOTFS" -xdev -mindepth 1 -printf '%P\0' \
            | LC_ALL=C sort -z
    )

    LC_ALL=C TZ=UTC E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" debugfs \
        -w \
        -f "$commands_file" \
        "$rootfs_image" >/dev/null 2>&1
}

function create_verity() {
    local rootfs_image="$ARTIFACT_DIR/rootfs.ext4"
    local verity_image="$ARTIFACT_DIR/rootfs.verity"
    local verity_info="$ARTIFACT_DIR/rootfs.verity.info"
    local verity_bytes
    local root_hash

    # SHA-256 dm-verity trees use less than 1% with 4 KiB blocks. Add one
    # fixed MiB for the superblock and round the partition blob to whole MiB.
    verity_bytes=$(((ROOTFS_IMAGE_BYTES + 99) / 100 + MIB))
    verity_bytes=$((((verity_bytes + MIB - 1) / MIB) * MIB))
    truncate --size="$verity_bytes" "$verity_image"

    LC_ALL=C veritysetup format \
        --uuid "$ROOTFS_VERITY_UUID" \
        --salt "$ROOTFS_VERITY_SALT" \
        --hash sha256 \
        --data-block-size "$BLOCK_SIZE" \
        --hash-block-size "$BLOCK_SIZE" \
        "$rootfs_image" \
        "$verity_image" > "$verity_info"

    root_hash="$(awk '$1 == "Root" && $2 == "hash:" {print $3}' "$verity_info")"
    [[ "$root_hash" =~ ^[0-9a-f]{64}$ ]] || fail "Could not read dm-verity root hash"
    printf '%s\n' "$root_hash" > "$ARTIFACT_DIR/rootfs_hash.txt"

    veritysetup verify "$rootfs_image" "$verity_image" "$root_hash"
}

function write_manifest() {
    (
        cd "$ARTIFACT_DIR"
        sha256sum rootfs.ext4 rootfs.verity rootfs_hash.txt rootfs.verity.info \
            > SHA256SUMS
    )
}

validate_inputs
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
prepare_rootfs
calculate_rootfs_size
create_ext4
create_verity
write_manifest
