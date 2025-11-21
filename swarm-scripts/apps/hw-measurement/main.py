#!/usr/bin/env python3

import sys
import os
import shutil
import platform
import subprocess
from typing import Tuple, Dict

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def get_cpu_total() -> int:
    """Get total logical CPU cores."""
    try:
        return os.cpu_count() or 0
    except Exception:
        return 0


def get_loadavg_5() -> float:
    """Get 5-minute load average from /proc/loadavg."""
    try:
        with open("/proc/loadavg", "r") as f:
            parts = f.read().strip().split()
            return float(parts[1])  # 5-minute load average
    except Exception:
        return 0.0


def get_cpu_avg_usage_percent() -> str:
    """Calculate approximate CPU usage from 5-min load average."""
    cpu_total = max(get_cpu_total(), 1)
    load5 = get_loadavg_5()
    usage = min(1.0, max(0.0, load5 / float(cpu_total))) * 100.0
    return f"{usage:.1f}"


def parse_meminfo() -> Tuple[int, int]:
    """Return (total_bytes, used_bytes) using MemTotal - MemAvailable."""
    meminfo: Dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if ":" not in line:
                    continue
                k, v = line.split(":", 1)
                v = v.strip()
                # Values are like '16338836 kB'
                num = v.split()[0]
                try:
                    meminfo[k] = int(num) * 1024  # to bytes
                except Exception:
                    pass
    except Exception:
        return 0, 0

    total = int(meminfo.get("MemTotal", 0))
    available = int(meminfo.get("MemAvailable", 0)) or int(meminfo.get("MemFree", 0))
    used = total - available if total and available else 0
    return total, used


def get_disk_usage_bytes() -> Tuple[int, int]:
    """Get disk usage for current working directory."""
    try:
        cwd = os.getcwd()
        usage = shutil.disk_usage(cwd)
        total = int(usage.total)
        used = int(usage.used)
        return total, used
    except Exception:
        return 0, 0


def try_cmd(cmd: list[str]) -> str:
    """Execute command and return output, or empty string on failure."""
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=3)
        return out.strip()
    except Exception:
        return ""


def detect_gpu() -> Tuple[bool, str]:
    """Detect GPU presence and model."""
    # Priority 1: nvidia-smi
    out = try_cmd(["bash", "-lc", "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader"])
    if out:
        # Could be multiple lines for multiple GPUs; join unique names
        names = sorted({line.strip() for line in out.splitlines() if line.strip()})
        return True, ", ".join(names)

    # Priority 2: lspci (might be absent in minimal images)
    lspci = try_cmd(["bash", "-lc", "command -v lspci >/dev/null 2>&1 && lspci -nnk | grep -iE 'vga|3d|gpu' -A2"])
    if lspci:
        # Heuristic: lines containing vendor/name
        for line in lspci.splitlines():
            low = line.lower()
            if any(v in low for v in ["nvidia", "amd", "advanced micro devices", "radeon", "intel corporation"]):
                return True, line.strip()

    # Priority 3: kernel devices (/dev/dri) as presence indicator
    if os.path.isdir("/dev/dri"):
        return True, "DRM device present"

    # Priority 4: Nvidia procfs info
    info = try_cmd(["bash", "-lc", "ls /proc/driver/nvidia/gpus/*/information 2>/dev/null | head -n1"])
    if info:
        content = try_cmd(["bash", "-lc", f"cat {info} 2>/dev/null | head -n1"])
        if content:
            return True, content.strip()

    return False, ""


def get_cpu_model() -> str:
    """Get CPU model name from /proc/cpuinfo or platform."""
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
                if line.lower().startswith("hardware") and not platform.machine().startswith("x86"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return platform.processor() or ""


def get_arch() -> str:
    """Get processor architecture."""
    return platform.machine() or ""


def measure_hardware() -> Dict[str, str]:
    """Measure all hardware parameters and return as dict."""
    cpu_total = get_cpu_total()
    cpu_avg_usage = get_cpu_avg_usage_percent()
    ram_total, ram_used = parse_meminfo()
    disk_total, disk_used = get_disk_usage_bytes()
    has_gpu, gpu_model = detect_gpu()
    processor_model = get_cpu_model()
    processor_arch = get_arch()

    props: Dict[str, str] = {
        "cpu_total": str(cpu_total),
        "cpu_avg_usage": str(cpu_avg_usage),
        "ram_total_bytes": str(ram_total),
        "ram_used_bytes": str(ram_used),
        "disk_total_bytes": str(disk_total),
        "disk_used_bytes": str(disk_used),
        "has_gpu": "true" if has_gpu else "false",
        "gpu_model": gpu_model,
        "processor_model": processor_model,
        "processor_arch": processor_arch,
    }

    return props


# Plugin commands

@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Initial hardware measurement and record as measurements."""
    local_node_id = input_data.local_node_id
    local_state = input_data.local_state or {}

    try:
        props = measure_hardware()
        print(f"[*] Measured hardware properties: {', '.join([k for k, v in props.items() if v])}", file=sys.stderr)

        # Convert to measurements
        measurements = []
        for name, value in props.items():
            if value:  # Only include non-empty values
                measurements.append({
                    "type": name,
                    "node": local_node_id,
                    "target_node": local_node_id,
                    "value": value
                })

        return PluginOutput(
            status='completed',
            measurements=measurements,
            local_state=local_state
        )
    except Exception as e:
        print(f"[!] Failed to measure hardware: {e}", file=sys.stderr)
        return PluginOutput(status='completed', local_state=local_state)


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Periodic hardware measurement (runs every 60 seconds)."""
    local_node_id = input_data.local_node_id
    local_state = input_data.local_state or {}

    try:
        props = measure_hardware()
        print(f"[*] Updated hardware properties: {', '.join([k for k, v in props.items() if v])}", file=sys.stderr)

        # Convert to measurements
        measurements = []
        for name, value in props.items():
            if value:  # Only include non-empty values
                measurements.append({
                    "type": name,
                    "node": local_node_id,
                    "target_node": local_node_id,
                    "value": value
                })

        return PluginOutput(
            status='completed',
            measurements=measurements,
            local_state=local_state
        )
    except Exception as e:
        print(f"[!] Failed to measure hardware: {e}", file=sys.stderr)
        return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Clean up - no action needed as measurements are time-series."""
    return PluginOutput(
        status='completed',
        local_state={}
    )


if __name__ == "__main__":
    plugin.run()
