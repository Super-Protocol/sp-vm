#!/usr/bin/env python3
"""
PKI Authority LXC container management helpers.
"""

import os
import sys
import subprocess
import shutil
import re
import yaml
import time
import urllib.request
import ssl
from pathlib import Path
from typing import List, Optional
from enum import Enum

PKI_SERVICE_NAME = "pki-authority"
SERVICE_INSIDE_CONTAINER = "tee-pki"
BRIDGE_NAME = "lxcbr0"
PCCS_PORT = "8081"
PKI_SERVICE_EXTERNAL_PORT = "8443"
CONTAINER_IP = "10.0.3.100"
WIREGUARD_INTERFACE = "wg0"
STORAGE_PATH = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/app/swarm-storage")


class VMMode(Enum):
    """VM mode types."""
    LEGACY = "legacy"
    SWARM_INIT = "swarm-init"
    SWARM_NORMAL = "swarm-normal"

class LXCContainer:
    """Manager for LXC container operations."""
    
    def __init__(self, container_name: str = PKI_SERVICE_NAME):
        self.container_name = container_name
    
    def start(self, timeout: int = 30) -> int:
        """Start LXC container. Returns exit code."""
        print(f"[*] Starting LXC container {self.container_name}")
        result = subprocess.run(
            ["lxc-start", "-n", self.container_name],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode
    
    def stop(self, graceful_timeout: int = 30, command_timeout: int = 60) -> int:
        """Stop LXC container gracefully. Returns exit code."""
        print(f"[*] Stopping LXC container {self.container_name} gracefully")
        result = subprocess.run(
            ["lxc-stop", "-n", self.container_name, "-t", str(graceful_timeout)],
            capture_output=True,
            text=True,
            timeout=command_timeout
        )
        return result.returncode
    
    def destroy(self) -> int:
        """Destroy LXC container. Returns exit code."""
        print(f"[*] Destroying LXC container {self.container_name}")
        result = subprocess.run(
            ["lxc-destroy", "-n", self.container_name, "-f"],
            capture_output=True,
            text=True,
            timeout=60
        )
        
        if result.returncode != 0:
            print(f"[!] Failed to destroy container: {result.stderr}", file=sys.stderr)
        
        return result.returncode
    
    def is_running(self) -> bool:
        """Check if LXC container is running."""
        try:
            result = subprocess.run(
                ["lxc-ls", "--running"],
                capture_output=True,
                text=True
            )
            if self.container_name not in result.stdout:
                print(f"[*] LXC container {self.container_name} is not running")
                return False
            return True
        except Exception as e:
            print(f"[!] Failed to check LXC container status: {e}", file=sys.stderr)
            return False
    
    def get_ip(self) -> Optional[str]:
        """Get container IP address."""
        try:
            result = subprocess.run(
                ["lxc-info", "-n", self.container_name, "-iH"],
                capture_output=True,
                text=True
            )
            container_ip = result.stdout.strip() if result.stdout.strip() else None
            return container_ip
        except Exception as e:
            print(f"[!] Failed to get container IP: {e}", file=sys.stderr)
            return None
    
    def create(self, archive_path: str = "/etc/super/containers/pki-authority/pki-authority.tar") -> bool:
        """Create LXC container if it doesn't exist. Returns True if created or already exists."""
        # Check if container already exists
        result = subprocess.run(
            ["lxc-info", "-n", self.container_name],
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            print(f"Container '{self.container_name}' already exists.")
            return True
        else:
            print(f"Container '{self.container_name}' not found. Creating...")
            try:
                subprocess.run(
                    [
                        "lxc-create",
                        "-n", self.container_name,
                        "-t", "oci",
                        "--",
                        "--url", f"docker-archive:{archive_path}"
                    ],
                    check=True
                )
                print(f"Container '{self.container_name}' created.")
                return True
            except subprocess.CalledProcessError as e:
                print(f"[!] Failed to create container: {e}", file=sys.stderr)
                return False
    
    def is_service_healthy(self, min_uptime: int = 120, healthcheck_url: str = "/healthcheck") -> bool:
        """Check if service inside container is running and healthy."""
        try:
            # 1. Check service status inside container
            result = subprocess.run(
                ["lxc-attach", "-n", self.container_name, "--", "systemctl", "is-active", SERVICE_INSIDE_CONTAINER],
                capture_output=True,
                text=True
            )
            status = result.stdout.strip()
            
            if status not in ["active", "activating"]:
                print(f"[*] Service {SERVICE_INSIDE_CONTAINER} status: {status}")
                return False
            
            # 2. If service is active, check how long it's been running
            if status == "active":
                result = subprocess.run(
                    ["lxc-attach", "-n", self.container_name, "--", "systemctl", "show", 
                     SERVICE_INSIDE_CONTAINER, "--property=ActiveEnterTimestamp"],
                    capture_output=True,
                    text=True
                )
                
                # Parse ActiveEnterTimestamp
                for line in result.stdout.split('\n'):
                    if line.startswith('ActiveEnterTimestamp='):
                        timestamp_str = line.split('=', 1)[1].strip()
                        if timestamp_str and timestamp_str != '0':
                            try:
                                # Get timestamp in seconds since epoch
                                ts_result = subprocess.run(
                                    ["date", "+%s", "-d", timestamp_str],
                                    capture_output=True,
                                    text=True
                                )
                                start_time = int(ts_result.stdout.strip())
                                current_time = int(time.time())
                                uptime_seconds = current_time - start_time
                                
                                # If running more than min_uptime, check healthcheck endpoint
                                if uptime_seconds > min_uptime:
                                    container_ip = self.get_ip()
                                    
                                    if container_ip:
                                        # Perform HTTPS healthcheck without certificate verification
                                        try:
                                            ctx = ssl.create_default_context()
                                            ctx.check_hostname = False
                                            ctx.verify_mode = ssl.CERT_NONE
                                            
                                            req = urllib.request.Request(f"https://{container_ip}{healthcheck_url}")
                                            with urllib.request.urlopen(req, context=ctx, timeout=5) as response:
                                                if response.status == 200:
                                                    return True
                                                else:
                                                    print(f"[*] Healthcheck returned status: {response.status}")
                                                    return False
                                        except Exception as e:
                                            print(f"[*] Healthcheck failed: {e}")
                                            return False
                            except Exception as e:
                                print(f"[*] Failed to parse service uptime: {e}")
            
            # Service is active or activating (but not ready for healthcheck yet)
            return True
            
        except Exception as e:
            print(f"[!] Failed to check service health: {e}", file=sys.stderr)
            return False


def detect_cpu_type() -> str:
    """Detect CPU type based on available devices."""
    if Path("/dev/tdx_guest").is_char_device():
        return "tdx"
    elif Path("/dev/sev-guest").is_char_device():
        return "sev-snp"
    else:
        return "untrusted"


def detect_vm_mode() -> VMMode:
    """Detect VM mode from kernel command line."""
    try:
        with open("/proc/cmdline", "r") as f:
            cmdline = f.read()
        
        if "vm_mode=legacy" in cmdline:
            return VMMode.LEGACY
        elif "vm_mode=swarm-init" in cmdline:
            return VMMode.SWARM_INIT
        else:
            return VMMode.SWARM_NORMAL
    except FileNotFoundError:
        return VMMode.SWARM_NORMAL


def patch_yaml_config(cpu_type: str):
    """Set own challenge type in LXC container configuration."""
    vm_mode = detect_vm_mode()
    
    if vm_mode == VMMode.LEGACY:
        template_name = "lxc-legacy-vm-template.yaml"
        print(f"Detected {vm_mode.value} mode, using legacy template")
    else:
        template_name = "lxc-swarm-template.yaml"
        print(f"Detected {vm_mode.value} mode, using swarm template")
    
    src_yaml = Path(f"/etc/super/containers/pki-authority/{template_name}")
    dst_yaml = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/app/conf/lxc.yaml")
    
    if not src_yaml.exists():
        print(f"Error: {src_yaml} not found.")
        sys.exit(1)
    
    # Load YAML, modify, and save
    with open(src_yaml, "r") as f:
        config = yaml.safe_load(f)
    
    # Set the CPU type in the configuration
    if "pki" not in config:
        config["pki"] = {}
    if "ownChallenge" not in config["pki"]:
        config["pki"]["ownChallenge"] = {}
    config["pki"]["ownChallenge"]["type"] = cpu_type
    
    # Set mode.attestationServiceSource.mode for swarm modes
    if vm_mode in (VMMode.SWARM_INIT, VMMode.SWARM_NORMAL):
        if "mode" not in config["pki"]:
            config["pki"]["mode"] = {}
        if "attestationServiceSource" not in config["pki"]["mode"]:
            config["pki"]["mode"]["attestationServiceSource"] = {}
        
        mode_value = "init" if vm_mode == VMMode.SWARM_INIT else "normal"
        config["pki"]["mode"]["attestationServiceSource"]["mode"] = mode_value
        print(f"Set attestationServiceSource mode to: {mode_value}")
    
    # Ensure destination directory exists
    dst_yaml.parent.mkdir(parents=True, exist_ok=True)
    
    # Write modified YAML
    with open(dst_yaml, "w") as f:
        yaml.dump(config, f, default_flow_style=False)
    
    print(f"Patched {dst_yaml} with type: {cpu_type}")


def set_subroot_env():
    """Copy trusted environment variables to container."""
    trusted_vars = [
        "AS__pki__baseDomain",
        "AS__pki__ownDomain",
        "AS__pki__certParams__ocspUrl",
        "AS__pki__mode__attestationServiceSource__baseUrl",
        "AS__pki__mode__attestationServiceSource__caBundle",
    ]
    
    src_subroot_env = Path("/sp/subroot.env")
    dst_subroot_env = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/app/subroot.env")
    
    if not src_subroot_env.exists():
        print(f"Info: {src_subroot_env} not found; skipping creation of {dst_subroot_env}")
        return
    
    # Remove destination first to ensure a clean recreate
    dst_subroot_env.unlink(missing_ok=True)
    
    # Read source file
    with open(src_subroot_env, "r") as f:
        lines = f.readlines()
    
    # Write destination with header
    with open(dst_subroot_env, "w") as f:
        f.write(f"# Autogenerated from {src_subroot_env}. Contains only trusted variables.\n")
        
        for var in trusted_vars:
            # Find first matching line
            for line in lines:
                if line.strip().startswith(f'{var}="'):
                    f.write(line)
                    break
    
    # Set permissions
    dst_subroot_env.chmod(0o644)
    print(f"Created {dst_subroot_env} with trusted variables.")


def patch_lxc_config(cpu_type: str):
    """Patch LXC container configuration."""
    config_file = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/config")
    config_bak = Path(f"{config_file}.bak")
    
    # Always restore config from backup if backup exists
    if config_bak.exists():
        shutil.copy(config_bak, config_file)
    else:
        # Create backup before first patch
        if config_file.exists():
            shutil.copy(config_file, config_bak)
    
    # Append MAC address configuration
    with open(config_file, "a") as f:
        f.write("lxc.net.0.hwaddr = 4e:fc:0a:d5:2d:ff\n")
    
    # Add device-specific configuration
    if cpu_type == "sev-snp":
        dev_path = Path("/dev/sev-guest")
        stat_info = dev_path.stat()
        dev_id = f"{os.major(stat_info.st_rdev)}:{os.minor(stat_info.st_rdev)}"
        
        with open(config_file, "a") as f:
            f.write(f"lxc.cgroup2.devices.allow = c {dev_id} rwm\n")
            f.write("lxc.mount.entry = /dev/sev-guest dev/sev-guest none bind,optional,create=file\n")
    
    elif cpu_type == "tdx":
        dev_path = Path("/dev/tdx_guest")
        stat_info = dev_path.stat()
        dev_id = f"{os.major(stat_info.st_rdev)}:{os.minor(stat_info.st_rdev)}"
        
        with open(config_file, "a") as f:
            f.write(f"lxc.cgroup2.devices.allow = c {dev_id} rwm\n")
            f.write("lxc.mount.entry = /dev/tdx_guest dev/tdx_guest none bind,optional,create=file\n")
            
            if Path("/etc/tdx-attest.conf").exists():
                f.write("lxc.mount.entry = /etc/tdx-attest.conf etc/tdx-attest.conf none bind,ro,create=file\n")


def get_bridge_ip(bridge_name: str) -> str:
    """Get host IP address on the LXC bridge."""
    result = subprocess.run(
        ["ip", "-4", "addr", "show", bridge_name],
        capture_output=True,
        text=True
    )
    
    if result.returncode != 0:
        print(f"Error: Could not determine IP address for bridge {bridge_name}")
        sys.exit(1)
    
    # Parse IP address from output
    match = re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+)', result.stdout)
    if not match:
        print(f"Error: Could not determine IP address for bridge {bridge_name}")
        sys.exit(1)
    
    return match.group(1)


def enable_route_localnet(bridge_name: str):
    """Enable route_localnet for the bridge."""
    sysctl_key = f"net.ipv4.conf.{bridge_name}.route_localnet"
    
    result = subprocess.run(
        ["sysctl", "-n", sysctl_key],
        capture_output=True,
        text=True
    )
    
    if result.returncode == 0 and result.stdout.strip() == "1":
        print(f"route_localnet already enabled for {bridge_name}")
    else:
        subprocess.run(
            ["sysctl", "-w", f"{sysctl_key}=1"],
            check=True
        )
        print(f"Enabled route_localnet for {bridge_name}")


def add_iptables_rule(host_ip: str, port: str):
    """Add iptables DNAT rule if it doesn't exist."""
    # Check if rule exists
    check_result = subprocess.run(
        [
            "iptables", "-t", "nat", "-C", "PREROUTING",
            "-p", "tcp",
            "-d", host_ip,
            "--dport", port,
            "-j", "DNAT",
            "--to-destination", f"127.0.0.1:{port}"
        ],
        capture_output=True
    )
    
    if check_result.returncode == 0:
        print(f"iptables DNAT rule already exists for {host_ip}:{port}")
    else:
        subprocess.run(
            [
                "iptables", "-t", "nat", "-A", "PREROUTING",
                "-p", "tcp",
                "-d", host_ip,
                "--dport", port,
                "-j", "DNAT",
                "--to-destination", f"127.0.0.1:{port}"
            ],
            check=True
        )
        print(f"iptables DNAT rule added: {host_ip}:{port} -> 127.0.0.1:{port}")

def delete_iptables_rules():
    """Delete all iptables NAT rules for PKI container."""
    host_ip = get_bridge_ip(BRIDGE_NAME)
    
    # Delete rules from all chains: PREROUTING, OUTPUT, POSTROUTING
    for chain in ["PREROUTING", "OUTPUT", "POSTROUTING"]:
        result = subprocess.run(
            ["iptables", "-t", "nat", "-S", chain],
            capture_output=True, text=True, check=True
        )
        
        rules = result.stdout.splitlines()
        
        for rule in rules:
            # Delete rules that contain host_ip or CONTAINER_IP
            if host_ip in rule or CONTAINER_IP in rule:
                delete_rule = rule.replace("-A", "-D", 1)
                subprocess.run(["iptables", "-t", "nat"] + delete_rule.split()[1:], check=True)
                print(f"Deleted iptables rule: {delete_rule}")


def setup_iptables(wg_ip):
    """Setup iptables NAT rules for LXC container access to host services."""
    host_ip = get_bridge_ip(BRIDGE_NAME)
    
    enable_route_localnet(BRIDGE_NAME)
    
    add_iptables_rule(host_ip, PCCS_PORT)

    subprocess.run(
        [
            "iptables", "-t", "nat", "-A", "PREROUTING",
            "-i", WIREGUARD_INTERFACE,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        check=True
    )
    print(f"Added iptables rule: PREROUTING WireGuard {PKI_SERVICE_EXTERNAL_PORT} -> {CONTAINER_IP}:443")
    
    subprocess.run(
        [
            "iptables", "-t", "nat", "-A", "OUTPUT",
            "-d", wg_ip,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        check=True
    )
    print(f"Added iptables rule: OUTPUT {wg_ip}:{PKI_SERVICE_EXTERNAL_PORT} -> {CONTAINER_IP}:443")
    
    subprocess.run(
        [
            "iptables", "-t", "nat", "-A", "POSTROUTING",
            "-s", f"{CONTAINER_IP}/32",
            "-j", "MASQUERADE"
        ],
        check=True
    )
    print(f"Added iptables rule: POSTROUTING MASQUERADE for {CONTAINER_IP}/32")



def update_pccs_url():
    """Update PCCS URL in QCNL configuration."""
    qcnl_conf = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/etc/sgx_default_qcnl.conf")
    qcnl_conf_bak = Path(f"{qcnl_conf}.bak")
    
    host_ip = get_bridge_ip(BRIDGE_NAME)
    
    pccs_url = f"https://{host_ip}:{PCCS_PORT}/sgx/certification/v4/"
    
    if not qcnl_conf.exists():
        print(f"Error: {qcnl_conf} not found")
        sys.exit(1)
    
    if not qcnl_conf_bak.exists():
        shutil.copy(qcnl_conf, qcnl_conf_bak)
    
    shutil.copy(qcnl_conf_bak, qcnl_conf)
    
    with open(qcnl_conf, "r") as f:
        content = f.read()
    
    content = re.sub(
        r'"pccs_url":\s*"[^"]*"',
        f'"pccs_url": "{pccs_url}"',
        content
    )
    
    with open(qcnl_conf, "w") as f:
        f.write(content)
    
    print(f"Updated PCCS URL in {qcnl_conf} to {pccs_url}")


def init_container():
    LXCContainer(PKI_SERVICE_NAME).create()


def get_node_tunnel_ip(node_id: str, wg_props: List[dict]) -> Optional[str]:
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def save_property_into_fs(file_name: str, content: bytes):
    STORAGE_PATH.mkdir(parents=True, exist_ok=True)
    file_path = STORAGE_PATH / file_name
    file_path.write_bytes(content)


def read_property_from_fs(file_name: str) -> tuple[bool, bytes]:
    file_path = STORAGE_PATH / file_name
    if file_path.exists():
        content = file_path.read_bytes()
        if content:
            return (True, content)
    return (False, b"")
