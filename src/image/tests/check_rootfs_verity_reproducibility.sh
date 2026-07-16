#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
DOCKERFILE="$REPOSITORY_ROOT/src/Dockerfile.rootfs-verity"
BUILD_CONTEXT="$REPOSITORY_ROOT/src"

ROOTFS_ARTIFACT_DIR="${ROOTFS_ARTIFACT_DIR:-${1:-}}"
RUN_COUNT="${ROOTFS_VERITY_REPRO_RUNS:-3}"
KEEP_OUTPUT="${KEEP_ROOTFS_VERITY_REPRO_OUTPUT:-0}"
UBUNTU_SNAPSHOT_ID="${UBUNTU_SNAPSHOT_ID:-20260714T000000Z}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1783987200}"
ROOTFS_UUID="${ROOTFS_UUID:-9d8ae77c-0f99-4b4c-a919-0de57b426ced}"
ROOTFS_DIR_HASH_SEED="${ROOTFS_DIR_HASH_SEED:-7ebf1975-28bf-544d-948f-5bb483eff52e}"
ROOTFS_VERITY_UUID="${ROOTFS_VERITY_UUID:-0ff7f592-c526-46f7-83d5-f47ad3f69e89}"
ROOTFS_VERITY_SALT="${ROOTFS_VERITY_SALT:-7ebf197528bf544d348f5bb483eff52ea41e0f99dac93882965f65924d1f87a6}"

if [[ -z "$ROOTFS_ARTIFACT_DIR" || ! -f "$ROOTFS_ARTIFACT_DIR/rootfs.tar" ]]; then
    echo "Usage: ROOTFS_ARTIFACT_DIR=/path/to/rootfs-export $0" >&2
    echo "The directory must contain the already-built rootfs.tar." >&2
    exit 2
fi
ROOTFS_ARTIFACT_DIR="$(realpath "$ROOTFS_ARTIFACT_DIR")"

if [[ ! "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]] || (( RUN_COUNT < 2 )); then
    echo "ROOTFS_VERITY_REPRO_RUNS must be an integer greater than or equal to 2" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d -t rootfs-verity-repro.XXXXXXXX)"

function cleanup() {
    local status=$?
    if (( status != 0 )) || [[ "$KEEP_OUTPUT" == "1" ]]; then
        echo "Rootfs ext4/dm-verity artifacts: $WORK_DIR" >&2
    else
        rm -rf "$WORK_DIR"
    fi
    return "$status"
}
trap cleanup EXIT

function build_rootfs_verity() {
    local run_number="$1"
    local output_dir="$WORK_DIR/run-$run_number"

    mkdir -p "$output_dir"
    echo "Building rootfs ext4/dm-verity run $run_number/$RUN_COUNT"
    docker buildx build \
        --file "$DOCKERFILE" \
        --target rootfs_verity_export \
        --no-cache \
        --pull=false \
        --allow security.insecure \
        --build-context "rootfs_input=$ROOTFS_ARTIFACT_DIR" \
        --build-arg "UBUNTU_SNAPSHOT_ID=$UBUNTU_SNAPSHOT_ID" \
        --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
        --build-arg "ROOTFS_UUID=$ROOTFS_UUID" \
        --build-arg "ROOTFS_DIR_HASH_SEED=$ROOTFS_DIR_HASH_SEED" \
        --build-arg "ROOTFS_VERITY_UUID=$ROOTFS_VERITY_UUID" \
        --build-arg "ROOTFS_VERITY_SALT=$ROOTFS_VERITY_SALT" \
        --output "type=local,dest=$output_dir" \
        "$BUILD_CONTEXT"

    (
        cd "$output_dir"
        sha256sum --check SHA256SUMS
    )
}

for ((run = 1; run <= RUN_COUNT; run++)); do
    build_rootfs_verity "$run"
done

reference_dir="$WORK_DIR/run-1"
for ((run = 2; run <= RUN_COUNT; run++)); do
    candidate_dir="$WORK_DIR/run-$run"
    if ! cmp --silent "$reference_dir/SHA256SUMS" "$candidate_dir/SHA256SUMS"; then
        echo "Rootfs ext4/dm-verity output differs between run 1 and run $run" >&2
        diff -u "$reference_dir/SHA256SUMS" "$candidate_dir/SHA256SUMS" >&2 || true
        diff -u "$reference_dir/rootfs.verity.info" "$candidate_dir/rootfs.verity.info" >&2 || true
        exit 1
    fi
done

echo "Rootfs ext4 and dm-verity are reproducible across $RUN_COUNT independent builds:"
cat "$reference_dir/SHA256SUMS"
