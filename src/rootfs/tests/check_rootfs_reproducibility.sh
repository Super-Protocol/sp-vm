#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
DOCKERFILE="$REPOSITORY_ROOT/src/Dockerfile"
BUILD_CONTEXT="$REPOSITORY_ROOT/src"

RUN_COUNT="${ROOTFS_REPRO_RUNS:-3}"
UBUNTU_SNAPSHOT_ID="${UBUNTU_SNAPSHOT_ID:-20260714T000000Z}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1783987200}"
KEEP_OUTPUT="${KEEP_ROOTFS_REPRO_OUTPUT:-0}"
SP_VM_BUILD_TYPE="${SP_VM_BUILD_TYPE:-release}"
SP_VM_IMAGE_VERSION="${SP_VM_IMAGE_VERSION:-rootfs-repro-test}"

if [[ ! "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]] || (( RUN_COUNT < 2 )); then
    echo "ROOTFS_REPRO_RUNS must be an integer greater than or equal to 2" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d -t rootfs-repro.XXXXXXXX)"

function cleanup() {
    local status=$?
    if (( status != 0 )) || [[ "$KEEP_OUTPUT" == "1" ]]; then
        echo "Rootfs reproducibility artifacts: $WORK_DIR" >&2
    else
        rm -rf "$WORK_DIR"
    fi
    return "$status"
}
trap cleanup EXIT

function build_rootfs() {
    local run_number="$1"
    local output_dir="$WORK_DIR/run-$run_number"
    mkdir -p "$output_dir"

    echo "Building complete logical rootfs run $run_number/$RUN_COUNT"
    docker buildx build \
        --file "$DOCKERFILE" \
        --target rootfs_export \
        --no-cache \
        --pull=false \
        --allow security.insecure \
        --build-arg "UBUNTU_SNAPSHOT_ID=$UBUNTU_SNAPSHOT_ID" \
        --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
        --build-arg "SP_VM_BUILD_TYPE=$SP_VM_BUILD_TYPE" \
        --build-arg "SP_VM_IMAGE_VERSION=$SP_VM_IMAGE_VERSION" \
        --output "type=local,dest=$output_dir" \
        "$BUILD_CONTEXT"

    (
        cd "$output_dir"
        sha256sum --check rootfs.tar.sha256
    )
}

function show_difference() {
    local reference_dir="$1"
    local candidate_dir="$2"

    echo "Package manifest difference:" >&2
    diff -u "$reference_dir/packages.manifest" "$candidate_dir/packages.manifest" >&2 || true

    echo "Filesystem metadata difference:" >&2
    diff -u "$reference_dir/rootfs.metadata" "$candidate_dir/rootfs.metadata" >&2 || true

    echo "Regular file content difference:" >&2
    diff -u "$reference_dir/rootfs.files.sha256" "$candidate_dir/rootfs.files.sha256" >&2 || true

    echo "Symlink target difference:" >&2
    diff -u "$reference_dir/rootfs.symlinks" "$candidate_dir/rootfs.symlinks" >&2 || true

    TZ=UTC tar --numeric-owner --list --verbose --file="$reference_dir/rootfs.tar" \
        > "$reference_dir/rootfs.list"
    TZ=UTC tar --numeric-owner --list --verbose --file="$candidate_dir/rootfs.tar" \
        > "$candidate_dir/rootfs.list"
    echo "Tar listing difference:" >&2
    diff -u "$reference_dir/rootfs.list" "$candidate_dir/rootfs.list" >&2 || true
}

for ((run = 1; run <= RUN_COUNT; run++)); do
    build_rootfs "$run"
done

reference_dir="$WORK_DIR/run-1"
reference_hash="$(awk '{print $1}' "$reference_dir/rootfs.tar.sha256")"

for ((run = 2; run <= RUN_COUNT; run++)); do
    candidate_dir="$WORK_DIR/run-$run"
    candidate_hash="$(awk '{print $1}' "$candidate_dir/rootfs.tar.sha256")"
    if [[ "$candidate_hash" != "$reference_hash" ]]; then
        echo "Logical rootfs is not reproducible: run 1 and run $run differ" >&2
        show_difference "$reference_dir" "$candidate_dir"
        exit 1
    fi
done

echo "Logical rootfs is reproducible across $RUN_COUNT clean builds: $reference_hash"
