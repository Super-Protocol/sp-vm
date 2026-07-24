#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
DOCKERFILE="$REPOSITORY_ROOT/src/Dockerfile.rootfs-verity"
BUILD_CONTEXT="$REPOSITORY_ROOT/src"

ROOTFS_ARTIFACT_DIR="${ROOTFS_ARTIFACT_DIR:-${1:-}}"
RUN_COUNT="${DISK_IMAGE_REPRO_RUNS:-3}"
KEEP_OUTPUT="${KEEP_DISK_IMAGE_REPRO_OUTPUT:-0}"
SP_VM_IMAGE_VERSION="${SP_VM_IMAGE_VERSION:-repro-test}"
UBUNTU_SNAPSHOT_ID="${UBUNTU_SNAPSHOT_ID:-20260714T000000Z}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1783987200}"

if [[ -z "$ROOTFS_ARTIFACT_DIR" || ! -f "$ROOTFS_ARTIFACT_DIR/rootfs.tar" ]]; then
    echo "Usage: ROOTFS_ARTIFACT_DIR=/path/to/rootfs-export $0" >&2
    echo "The directory must contain the already-built rootfs.tar." >&2
    exit 2
fi
ROOTFS_ARTIFACT_DIR="$(realpath "$ROOTFS_ARTIFACT_DIR")"

if [[ ! "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]] || (( RUN_COUNT < 2 )); then
    echo "DISK_IMAGE_REPRO_RUNS must be an integer greater than or equal to 2" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d -t disk-image-repro.XXXXXXXX)"
IMAGE_FILENAME="sp-vm-${SP_VM_IMAGE_VERSION}.img"

function cleanup() {
    local status=$?
    if (( status != 0 )) || [[ "$KEEP_OUTPUT" == "1" ]]; then
        echo "Disk image reproducibility artifacts: $WORK_DIR" >&2
    else
        rm -rf "$WORK_DIR"
    fi
    return "$status"
}
trap cleanup EXIT

function build_disk_image() {
    local run_number="$1"
    local output_dir="$WORK_DIR/run-$run_number"

    mkdir -p "$output_dir"
    echo "Building complete disk image run $run_number/$RUN_COUNT"
    docker buildx build \
        --file "$DOCKERFILE" \
        --target disk_image_export \
        --no-cache \
        --pull=false \
        --allow security.insecure \
        --build-context "rootfs_input=$ROOTFS_ARTIFACT_DIR" \
        --build-arg "UBUNTU_SNAPSHOT_ID=$UBUNTU_SNAPSHOT_ID" \
        --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
        --build-arg "SP_VM_IMAGE_VERSION=$SP_VM_IMAGE_VERSION" \
        --output "type=local,dest=$output_dir" \
        "$BUILD_CONTEXT"

    test -s "$output_dir/$IMAGE_FILENAME"
    test -s "$output_dir/rootfs_hash.txt"
    (
        cd "$output_dir"
        sha256sum "$IMAGE_FILENAME" rootfs_hash.txt > SHA256SUMS
    )
}

for ((run = 1; run <= RUN_COUNT; run++)); do
    build_disk_image "$run"
done

reference_dir="$WORK_DIR/run-1"
for ((run = 2; run <= RUN_COUNT; run++)); do
    candidate_dir="$WORK_DIR/run-$run"
    if ! cmp --silent "$reference_dir/SHA256SUMS" "$candidate_dir/SHA256SUMS"; then
        echo "Complete disk image differs between run 1 and run $run" >&2
        diff -u "$reference_dir/SHA256SUMS" "$candidate_dir/SHA256SUMS" >&2 || true
        cmp --verbose "$reference_dir/$IMAGE_FILENAME" "$candidate_dir/$IMAGE_FILENAME" \
            2>&1 | sed -n '1,20p' >&2 || true
        exit 1
    fi
done

echo "Complete disk image is reproducible across $RUN_COUNT independent builds:"
cat "$reference_dir/SHA256SUMS"
