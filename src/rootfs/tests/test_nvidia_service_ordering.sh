#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_NVIDIA_TEST_INSTALLED_ROOT:-}" ]]; then
    config_dir="$SP_NVIDIA_TEST_INSTALLED_ROOT"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/etc/systemd/system"
    pki_unit_dir="$unit_dir"
else
    config_dir="$repository_root/src/rootfs/files/configs"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/etc/systemd/system"
    pki_unit_dir="$config_dir/pki-service/systemd"
fi
test_root="$(mktemp -d -t sp-nvidia-ordering.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_pci_device() {
    local root="$1" bdf="$2" vendor="$3" device="$4" vpd="${5:-}"
    mkdir -p "$root/pci/$bdf"
    printf '%s\n' "$vendor" > "$root/pci/$bdf/vendor"
    printf '%s\n' "$device" > "$root/pci/$bdf/device"
    printf '%s\n' 0x030200 > "$root/pci/$bdf/class"
    printf '%s\n' "$vpd" > "$root/pci/$bdf/vpd"
}

cat > "$test_root/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$SP_TEST_SYSTEMCTL_LOG"
case "$1:${2:-}:${3:-}" in
    is-active:--quiet:nvidia-fabricmanager.service)
        [[ -f "$SP_TEST_STATE/fabric-active" ]]
        ;;
    is-active:--quiet:nvidia-persistenced.service)
        [[ -f "$SP_TEST_STATE/persistence-active" ]]
        ;;
    start:nvidia-persistenced.service:|restart:nvidia-persistenced.service:)
        if [[ -f "$SP_TEST_STATE/fabric-required" && ! -f "$SP_TEST_STATE/fabric-active" ]]; then
            echo "persistence started before Fabric Manager" >&2
            exit 90
        fi
        touch "$SP_TEST_STATE/persistence-active" "$SP_NVIDIA_READY_FILE"
        ;;
    reset-failed:nvidia-persistenced.service:)
        ;;
    *)
        echo "unexpected systemctl call: $*" >&2
        exit 91
        ;;
esac
EOF
chmod +x "$test_root/systemctl"

# Exact detection: an ordinary Mellanox function is not NVLink management.
mkdir -p "$test_root/pcie/pci" "$test_root/pcie/dev"
make_pci_device "$test_root/pcie" 0000:01:00.0 0x15b3 0x1021 ordinary_nic
! SP_SYSFS_PCI_DEVICES_DIR="$test_root/pcie/pci" \
    SP_DEVICE_ROOT="$test_root/pcie/dev" \
    "$bin_dir/sp-nvidia-fabricmanager-condition" >/dev/null \
    || fail "ordinary CX7 was classified as NVLink management"

# PCIe-only guests pass the barrier without querying or requiring FM.
mkdir -p "$test_root/pcie/state" "$test_root/pcie/run"
touch "$test_root/pcie/state/persistence-active" "$test_root/pcie/run/cc-ready"
: > "$test_root/pcie/systemctl.log"
SP_SYSFS_PCI_DEVICES_DIR="$test_root/pcie/pci" \
SP_DEVICE_ROOT="$test_root/pcie/dev" \
SP_NVIDIA_FABRIC_CONDITION="$bin_dir/sp-nvidia-fabricmanager-condition" \
SP_SYSTEMCTL="$test_root/systemctl" \
SP_TEST_SYSTEMCTL_LOG="$test_root/pcie/systemctl.log" \
SP_TEST_STATE="$test_root/pcie/state" \
SP_NVIDIA_READY_FILE="$test_root/pcie/run/cc-ready" \
SP_SLEEP=/bin/true \
    "$bin_dir/sp-nvidia-gpu-ready"
! grep -q fabricmanager "$test_root/pcie/systemctl.log" \
    || fail "PCIe-only barrier queried Fabric Manager"

# NVLink guests start persistence only after FM is active.
mkdir -p "$test_root/nvlink/pci" "$test_root/nvlink/dev" "$test_root/nvlink/state" "$test_root/nvlink/run"
make_pci_device "$test_root/nvlink" 0000:ab:00.0 0x15b3 0x1021 SW_MNG
touch "$test_root/nvlink/state/fabric-required" "$test_root/nvlink/state/fabric-active"
: > "$test_root/nvlink/systemctl.log"
SP_SYSFS_PCI_DEVICES_DIR="$test_root/nvlink/pci" \
SP_DEVICE_ROOT="$test_root/nvlink/dev" \
SP_NVIDIA_FABRIC_CONDITION="$bin_dir/sp-nvidia-fabricmanager-condition" \
SP_SYSTEMCTL="$test_root/systemctl" \
SP_TEST_SYSTEMCTL_LOG="$test_root/nvlink/systemctl.log" \
SP_TEST_STATE="$test_root/nvlink/state" \
SP_NVIDIA_READY_FILE="$test_root/nvlink/run/cc-ready" \
SP_SLEEP=/bin/true \
    "$bin_dir/sp-nvidia-gpu-ready"
first_fm_line="$(grep -n 'is-active --quiet nvidia-fabricmanager.service' "$test_root/nvlink/systemctl.log" | head -n1 | cut -d: -f1)"
start_persistence_line="$(grep -n 'start nvidia-persistenced.service' "$test_root/nvlink/systemctl.log" | head -n1 | cut -d: -f1)"
[[ -n "$first_fm_line" && -n "$start_persistence_line" && "$first_fm_line" -lt "$start_persistence_line" ]] \
    || fail "persistence was not ordered after active Fabric Manager"

# A failed FM never causes persistence (and therefore nvidia-smi/PKI) attempts.
rm -f "$test_root/nvlink/state/fabric-active" "$test_root/nvlink/state/persistence-active" \
    "$test_root/nvlink/run/cc-ready"
: > "$test_root/nvlink/systemctl.log"
if SP_SYSFS_PCI_DEVICES_DIR="$test_root/nvlink/pci" \
    SP_DEVICE_ROOT="$test_root/nvlink/dev" \
    SP_NVIDIA_FABRIC_CONDITION="$bin_dir/sp-nvidia-fabricmanager-condition" \
    SP_SYSTEMCTL="$test_root/systemctl" \
    SP_TEST_SYSTEMCTL_LOG="$test_root/nvlink/systemctl.log" \
    SP_TEST_STATE="$test_root/nvlink/state" \
    SP_NVIDIA_READY_FILE="$test_root/nvlink/run/cc-ready" \
    SP_NVIDIA_READY_TIMEOUT=0 \
    SP_SLEEP=/bin/true \
        "$bin_dir/sp-nvidia-gpu-ready"; then
    fail "barrier succeeded while Fabric Manager was inactive"
fi
! grep -q nvidia-persistenced.service "$test_root/nvlink/systemctl.log" \
    || fail "barrier touched persistence while Fabric Manager was inactive"

# The persistence unit's own condition independently closes the early-start path.
! SP_SYSFS_PCI_DEVICES_DIR="$test_root/nvlink/pci" \
    SP_DEVICE_ROOT="$test_root/nvlink/dev" \
    SP_NVIDIA_FABRIC_CONDITION="$bin_dir/sp-nvidia-fabricmanager-condition" \
    SP_SYSTEMCTL="$test_root/systemctl" \
    SP_TEST_SYSTEMCTL_LOG="$test_root/nvlink/systemctl.log" \
    SP_TEST_STATE="$test_root/nvlink/state" \
        "$bin_dir/sp-nvidia-persistenced-condition" \
    || fail "persistence condition allowed inactive FM"
touch "$test_root/nvlink/state/fabric-active"
SP_SYSFS_PCI_DEVICES_DIR="$test_root/nvlink/pci" \
SP_DEVICE_ROOT="$test_root/nvlink/dev" \
SP_NVIDIA_FABRIC_CONDITION="$bin_dir/sp-nvidia-fabricmanager-condition" \
SP_SYSTEMCTL="$test_root/systemctl" \
SP_TEST_SYSTEMCTL_LOG="$test_root/nvlink/systemctl.log" \
SP_TEST_STATE="$test_root/nvlink/state" \
    "$bin_dir/sp-nvidia-persistenced-condition"

# An exact SW_MNG function must expose a subnet-management-capable LinkUp port.
mkdir -p "$test_root/nvlink/infiniband/mlx5_0/ports/1"
ln -s "$test_root/nvlink/pci/0000:ab:00.0" "$test_root/nvlink/infiniband/mlx5_0/device"
printf '%s\n' 0x0 > "$test_root/nvlink/infiniband/mlx5_0/ports/1/cap_mask"
printf '%s\n' '3: Disabled' > "$test_root/nvlink/infiniband/mlx5_0/ports/1/phys_state"
! SP_SYSFS_PCI_DEVICES_DIR="$test_root/nvlink/pci" \
    SP_SYSFS_INFINIBAND_DIR="$test_root/nvlink/infiniband" \
    SP_NVIDIA_CX7_LINK_TIMEOUT=0 \
    SP_SLEEP=/bin/true \
        "$bin_dir/sp-nvidia-wait-cx7-linkup" \
    || fail "CX7 wait accepted a non-LinkUp port"
printf '%s\n' '5: LinkUp' > "$test_root/nvlink/infiniband/mlx5_0/ports/1/phys_state"
SP_SYSFS_PCI_DEVICES_DIR="$test_root/nvlink/pci" \
SP_SYSFS_INFINIBAND_DIR="$test_root/nvlink/infiniband" \
SP_NVIDIA_CX7_LINK_TIMEOUT=0 \
SP_SLEEP=/bin/true \
    "$bin_dir/sp-nvidia-wait-cx7-linkup"

# The CC marker is published only after nvidia-smi -srs succeeds.
cat > "$test_root/nvidia-smi" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$SP_TEST_NVIDIA_SMI_LOG"
attempts="$(wc -l < "$SP_TEST_NVIDIA_SMI_LOG")"
(( attempts >= 2 ))
EOF
chmod +x "$test_root/nvidia-smi"
: > "$test_root/nvidia-smi.log"
mkdir -p "$test_root/cc-run"
SP_NVIDIA_SMI="$test_root/nvidia-smi" \
SP_TEST_NVIDIA_SMI_LOG="$test_root/nvidia-smi.log" \
SP_NVIDIA_READY_DIR="$test_root/cc-run" \
SP_NVIDIA_CC_MAX_ATTEMPTS=2 \
SP_SLEEP=/bin/true \
    "$bin_dir/sp-nvidia-enable-cc-ready"
[[ -f "$test_root/cc-run/cc-ready" ]] || fail "successful CC setup did not publish readiness"
[[ "$(wc -l < "$test_root/nvidia-smi.log")" -eq 2 ]] || fail "CC setup did not use bounded retry"
grep -qx 'conf-compute -srs 1' "$test_root/nvidia-smi.log" \
    || fail "CC setup invoked an unexpected nvidia-smi command"

# Test both PKI entry points separately; their retry loops cannot bypass readiness.
for pki_service in pki-cert-init pki-authority-sync; do
    pki_unit="$pki_unit_dir/$pki_service.service"
    grep -q '^Requires=.*sp-nvidia-gpu-ready.service' "$pki_unit" \
        || fail "$pki_service does not require the GPU-ready barrier"
    grep -q '^After=.*sp-nvidia-gpu-ready.service' "$pki_unit" \
        || fail "$pki_service is not ordered after the GPU-ready barrier"
done

grep -q '^Requires=sp-nvidia-gpu-ready.service' \
    "$pki_unit_dir/pki-vm-measurements.service" \
    || fail "PKI measurements can bypass the GPU-ready barrier"
grep -q '^Requires=sp-nvidia-gpu-ready.service' \
    "$unit_dir/nvidia-cdi-refresh.service.d/10-sp-gpu-ready.conf" \
    || fail "CDI path activation can bypass the GPU-ready barrier"

echo "NVIDIA service ordering tests passed"
