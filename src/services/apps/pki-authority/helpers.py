#!/usr/bin/env python3
"""
PKI Authority LXC container management helpers.
"""

import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import List, Optional

import yaml

PKI_SERVICE_NAME = "pki-authority"
SERVICE_INSIDE_CONTAINER = "tee-pki"
BRIDGE_NAME = "lxcbr0"
PCCS_PORT = "8081"
PKI_SERVICE_EXTERNAL_PORT = "8443"
CONTAINER_IP = "10.0.3.100"
WIREGUARD_INTERFACE = "wg0"
STORAGE_PATH = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/app/swarm-storage")
IPTABLES_RULE_COMMENT = f"{PKI_SERVICE_NAME}-rule"
SWARM_ENV_YAML = "/sp/swarm/swarm-env.yaml"


class LogLevel(Enum):
    """Log levels for structured logging."""
    INFO = "INFO"
    WARN = "WARN"
    ERROR = "ERROR"
    DEBUG = "DEBUG"


def log(level: LogLevel, message: str):
    """Log message with timestamp, service name and level."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{PKI_SERVICE_NAME}] [{level.value}] {message}", file=sys.stderr)


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
        log(LogLevel.INFO, f"Starting LXC container {self.container_name}")
        result = subprocess.run(
            ["lxc-start", "-n", self.container_name],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False
        )
        return result.returncode

    def stop(self, graceful_timeout: int = 30, command_timeout: int = 60) -> int:
        """Stop LXC container gracefully. Returns exit code."""
        log(LogLevel.INFO, f"Stopping LXC container {self.container_name} gracefully")
        result = subprocess.run(
            ["lxc-stop", "-n", self.container_name, "-t", str(graceful_timeout)],
            capture_output=True,
            text=True,
            timeout=command_timeout,
            check=False
        )
        return result.returncode

    def destroy(self) -> int:
        """Destroy LXC container. Returns exit code."""
        log(LogLevel.INFO, f"Destroying LXC container {self.container_name}")
        result = subprocess.run(
            ["lxc-destroy", "-n", self.container_name, "-f"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False
        )

        if result.returncode != 0:
            log(LogLevel.ERROR, f"Failed to destroy container: {result.stderr}")

        return result.returncode

    def is_running(self) -> bool:
        """Check if LXC container is running."""
        try:
            result = subprocess.run(
                ["lxc-ls", "--running"],
                capture_output=True,
                text=True,
                check=False
            )
            if self.container_name not in result.stdout:
                log(LogLevel.INFO, f"LXC container {self.container_name} is not running")
                return False
            return True
        except Exception as error:  # pylint: disable=broad-exception-caught
            log(LogLevel.ERROR, f"Failed to check LXC container status: {error}")
            return False

    def get_ip(self) -> Optional[str]:
        """Get container IP address."""
        try:
            result = subprocess.run(
                ["lxc-info", "-n", self.container_name, "-iH"],
                capture_output=True,
                text=True,
                check=False
            )
            container_ip = result.stdout.strip() if result.stdout.strip() else None
            return container_ip
        except Exception as error:  # pylint: disable=broad-exception-caught
            log(LogLevel.ERROR, f"Failed to get container IP: {error}")
            return None

    def create(
        self,
        archive_path: str = "/etc/super/containers/pki-authority/pki-authority.tar"
    ) -> bool:
        """Create LXC container if it doesn't exist.

        Returns True if created or already exists.
        """
        # Check if container already exists
        result = subprocess.run(
            ["lxc-info", "-n", self.container_name],
            capture_output=True,
            text=True,
            check=False
        )

        if result.returncode == 0:
            log(LogLevel.INFO, f"Container '{self.container_name}' already exists.")
            return True

        log(LogLevel.INFO, f"Container '{self.container_name}' not found. Creating...")
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
            log(LogLevel.INFO, f"Container '{self.container_name}' created.")
            return True
        except subprocess.CalledProcessError as error:
            log(LogLevel.ERROR, f"Failed to create container: {error}")
            return False

    def is_service_healthy(self, min_uptime: int = 120, healthcheck_url: str = "/healthcheck") -> bool:
        """Check if service inside container is running and healthy."""
        try:
            # 1. Check service status inside container
            result = subprocess.run(
                [
                    "lxc-attach", "-n", self.container_name, "--",
                    "systemctl", "is-active", SERVICE_INSIDE_CONTAINER
                ],
                capture_output=True,
                text=True,
                check=False
            )
            status = result.stdout.strip()

            if status not in ["active", "activating"]:
                log(LogLevel.INFO, f"Service {SERVICE_INSIDE_CONTAINER} status: {status}")
                return False

            # If service is active, check how long it's been running
            if status == "active":
                result = subprocess.run(
                    [
                        "lxc-attach", "-n", self.container_name, "--",
                        "systemctl", "show",
                        SERVICE_INSIDE_CONTAINER,
                        "--property=ActiveEnterTimestamp"
                    ],
                    capture_output=True,
                    text=True,
                    check=False
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
                                    text=True,
                                    check=False
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

                                            req = urllib.request.Request(
                                                f"https://{container_ip}{healthcheck_url}"
                                            )
                                            with urllib.request.urlopen(
                                                req, context=ctx, timeout=5
                                            ) as response:
                                                if response.status == 200:
                                                    return True

                                                log(
                                                    LogLevel.INFO,
                                                    f"Healthcheck returned status: "
                                                    f"{response.status}"
                                                )
                                                return False
                                        except Exception as error:  # pylint: disable=broad-exception-caught
                                            log(
                                                LogLevel.INFO,
                                                f"Healthcheck failed: {error}"
                                            )
                                            return False
                            except Exception as error:  # pylint: disable=broad-exception-caught
                                log(
                                    LogLevel.INFO,
                                    f"Failed to parse service uptime: {error}"
                                )

            # Service is active or activating (but not ready for healthcheck yet)
            return True

        except Exception as error:  # pylint: disable=broad-exception-caught
            log(LogLevel.ERROR, f"Failed to check service health: {error}")
            return False


def detect_cpu_type() -> str:
    """Detect CPU type based on available devices."""
    if Path("/dev/tdx_guest").is_char_device():
        return "tdx"
    if Path("/dev/sev-guest").is_char_device():
        return "sev-snp"
    return "untrusted"


def detect_vm_mode() -> VMMode:
    """Detect VM mode from kernel command line."""
    try:
        with open("/proc/cmdline", "r", encoding="utf-8") as file:
            cmdline = file.read()

        if "vm_mode=legacy" in cmdline:
            return VMMode.LEGACY
        if "vm_mode=swarm-init" in cmdline:
            return VMMode.SWARM_INIT
        return VMMode.SWARM_NORMAL
    except FileNotFoundError:
        return VMMode.SWARM_NORMAL


def get_pki_domain() -> str:
    """Read PKI authority domain from swarm-env.yaml.

    Returns:
        Domain string.

    Raises:
        FileNotFoundError: If swarm-env.yaml does not exist.
        ValueError: If configuration is empty or domain is not found.
        Exception: For other errors during reading.
    """
    swarm_env_path = Path(SWARM_ENV_YAML)

    if not swarm_env_path.exists():
        error_msg = f"Swarm environment config not found: {SWARM_ENV_YAML}"
        log(LogLevel.ERROR, error_msg)
        raise FileNotFoundError(error_msg)

    try:
        with open(swarm_env_path, "r", encoding="utf-8") as file:
            config = yaml.safe_load(file)

        if not config:
            error_msg = f"Empty configuration in {SWARM_ENV_YAML}"
            log(LogLevel.ERROR, error_msg)
            raise ValueError(error_msg)

        domain = config.get("pki-authority", {}).get("domain")
        if not domain:
            error_msg = f"No domain found in {SWARM_ENV_YAML} under pki-authority.domain"
            log(LogLevel.ERROR, error_msg)
            raise ValueError(error_msg)

        log(LogLevel.INFO, f"Read PKI domain from config: {domain}")
        return domain

    except (FileNotFoundError, ValueError):
        raise
    except Exception as error:  # pylint: disable=broad-exception-caught
        error_msg = f"Failed to read domain from {SWARM_ENV_YAML}: {error}"
        log(LogLevel.ERROR, error_msg)
        raise Exception(error_msg) from error


def patch_yaml_config(cpu_type: str, vm_mode: VMMode, pki_domain: str):
    """Set own challenge type in LXC container configuration."""
    if vm_mode == VMMode.LEGACY:
        template_name = "lxc-legacy-vm-template.yaml"
        log(
            LogLevel.INFO,
            f"Detected {vm_mode.value} mode, using legacy template"
        )
    else:
        template_name = "lxc-swarm-template.yaml"
        log(
            LogLevel.INFO,
            f"Detected {vm_mode.value} mode, using swarm template"
        )

    src_yaml = Path(f"/etc/super/containers/pki-authority/{template_name}")
    dst_yaml = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/app/conf/lxc.yaml")

    if not src_yaml.exists():
        log(LogLevel.ERROR, f"Error: {src_yaml} not found.")
        sys.exit(1)

    # Load YAML, modify, and save
    with open(src_yaml, "r", encoding="utf-8") as file:
        config = yaml.safe_load(file)

    # Set the CPU type in the configuration
    if "pki" not in config:
        config["pki"] = {}
    if "ownChallenge" not in config["pki"]:
        config["pki"]["ownChallenge"] = {}
    config["pki"]["ownChallenge"]["type"] = cpu_type

    # Set ownDomain from parameter
    if pki_domain:
        config["pki"]["ownDomain"] = pki_domain
        log(LogLevel.INFO, f"Set ownDomain to: {pki_domain}")

    # Set mode.attestationServiceSource.mode for swarm modes
    if vm_mode in (VMMode.SWARM_INIT, VMMode.SWARM_NORMAL):
        if "mode" not in config["pki"]:
            config["pki"]["mode"] = {}
        if "attestationServiceSource" not in config["pki"]["mode"]:
            config["pki"]["mode"]["attestationServiceSource"] = {}

        mode_value = "init" if vm_mode == VMMode.SWARM_INIT else "normal"
        config["pki"]["mode"]["attestationServiceSource"]["mode"] = mode_value
        log(LogLevel.INFO, f"Set attestationServiceSource mode to: {mode_value}")

    # Ensure destination directory exists
    dst_yaml.parent.mkdir(parents=True, exist_ok=True)

    # Write modified YAML
    with open(dst_yaml, "w", encoding="utf-8") as file:
        yaml.dump(config, file, default_flow_style=False)


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
    with open(config_file, "a", encoding="utf-8") as file:
        file.write("lxc.net.0.hwaddr = 4e:fc:0a:d5:2d:ff\n")

    # Add device-specific configuration
    if cpu_type == "sev-snp":
        dev_path = Path("/dev/sev-guest")
        stat_info = dev_path.stat()
        dev_id = f"{os.major(stat_info.st_rdev)}:{os.minor(stat_info.st_rdev)}"

        with open(config_file, "a", encoding="utf-8") as file:
            file.write(f"lxc.cgroup2.devices.allow = c {dev_id} rwm\n")
            file.write(
                "lxc.mount.entry = /dev/sev-guest dev/sev-guest "
                "none bind,optional,create=file\n"
            )

    elif cpu_type == "tdx":
        dev_path = Path("/dev/tdx_guest")
        stat_info = dev_path.stat()
        dev_id = f"{os.major(stat_info.st_rdev)}:{os.minor(stat_info.st_rdev)}"

        with open(config_file, "a", encoding="utf-8") as file:
            file.write(f"lxc.cgroup2.devices.allow = c {dev_id} rwm\n")
            file.write(
                "lxc.mount.entry = /dev/tdx_guest dev/tdx_guest "
                "none bind,optional,create=file\n"
            )

            if Path("/etc/tdx-attest.conf").exists():
                file.write(
                    "lxc.mount.entry = /etc/tdx-attest.conf etc/tdx-attest.conf "
                    "none bind,ro,create=file\n"
                )


def get_bridge_ip(bridge_name: str) -> str:
    """Get host IP address on the LXC bridge."""
    result = subprocess.run(
        ["ip", "-4", "addr", "show", bridge_name],
        capture_output=True,
        text=True,
        check=False
    )

    if result.returncode != 0:
        log(
            LogLevel.ERROR,
            f"Error: Could not determine IP address for bridge {bridge_name}"
        )
        sys.exit(1)

    # Parse IP address from output
    match = re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+)', result.stdout)
    if not match:
        log(
            LogLevel.ERROR,
            f"Error: Could not determine IP address for bridge {bridge_name}"
        )
        sys.exit(1)

    return match.group(1)


def enable_route_localnet(bridge_name: str):
    """Enable route_localnet for the bridge."""
    sysctl_key = f"net.ipv4.conf.{bridge_name}.route_localnet"

    result = subprocess.run(
        ["sysctl", "-n", sysctl_key],
        capture_output=True,
        text=True,
        check=False
    )

    if result.returncode == 0 and result.stdout.strip() == "1":
        log(LogLevel.INFO, f"route_localnet already enabled for {bridge_name}")
    else:
        subprocess.run(
            ["sysctl", "-w", f"{sysctl_key}=1"],
            check=True
        )
        log(LogLevel.INFO, f"Enabled route_localnet for {bridge_name}")


def delete_iptables_rules():
    """Delete all iptables NAT rules for PKI container."""
    # Delete rules from all chains: PREROUTING, OUTPUT, POSTROUTING
    for chain in ["PREROUTING", "OUTPUT", "POSTROUTING"]:
        result = subprocess.run(
            ["iptables", "-t", "nat", "-S", chain],
            capture_output=True, text=True, check=True
        )

        rules = result.stdout.splitlines()

        for rule in rules:
            # Delete rules that contain our comment
            if IPTABLES_RULE_COMMENT in rule:
                delete_rule = rule.replace("-A", "-D", 1)
                subprocess.run(["iptables", "-t", "nat"] + delete_rule.split()[1:], check=True)
                log(LogLevel.INFO, f"Deleted iptables rule: {delete_rule}")


def ensure_iptables_rule(check_args: List[str], add_args: List[str], description: str):
    """Ensure iptables rule exists, add if missing."""
    log(LogLevel.INFO, f"Checking iptables rule: {description}")

    check_result = subprocess.run(check_args, capture_output=True, check=False)

    if check_result.returncode == 0:
        log(LogLevel.INFO, "Rule already exists")
    else:
        subprocess.run(add_args, check=True)
        log(LogLevel.INFO, "Rule added")

def setup_iptables(wg_ip):
    """Setup iptables NAT rules for LXC container access to host services."""
    host_ip = get_bridge_ip(BRIDGE_NAME)

    enable_route_localnet(BRIDGE_NAME)

    # Rule 1: PCCS DNAT
    ensure_iptables_rule(
        check_args=[
            "iptables", "-t", "nat", "-C", "PREROUTING",
            "-p", "tcp",
            "-d", host_ip,
            "--dport", PCCS_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"127.0.0.1:{PCCS_PORT}"
        ],
        add_args=[
            "iptables", "-t", "nat", "-A", "PREROUTING",
            "-p", "tcp",
            "-d", host_ip,
            "--dport", PCCS_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"127.0.0.1:{PCCS_PORT}"
        ],
        description=f"PCCS DNAT {host_ip}:{PCCS_PORT} -> 127.0.0.1:{PCCS_PORT}"
    )

    # Rule 2: WireGuard PREROUTING
    ensure_iptables_rule(
        check_args=[
            "iptables", "-t", "nat", "-C", "PREROUTING",
            "-i", WIREGUARD_INTERFACE,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        add_args=[
            "iptables", "-t", "nat", "-A", "PREROUTING",
            "-i", WIREGUARD_INTERFACE,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        description=f"PREROUTING WireGuard {PKI_SERVICE_EXTERNAL_PORT} -> {CONTAINER_IP}:443"
    )

    # Rule 3: OUTPUT
    ensure_iptables_rule(
        check_args=[
            "iptables", "-t", "nat", "-C", "OUTPUT",
            "-d", wg_ip,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        add_args=[
            "iptables", "-t", "nat", "-A", "OUTPUT",
            "-d", wg_ip,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        description=f"OUTPUT {wg_ip}:{PKI_SERVICE_EXTERNAL_PORT} -> {CONTAINER_IP}:443"
    )

    # Rule 4: MASQUERADE
    ensure_iptables_rule(
        check_args=[
            "iptables", "-t", "nat", "-C", "POSTROUTING",
            "-s", f"{CONTAINER_IP}/32",
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "MASQUERADE"
        ],
        add_args=[
            "iptables", "-t", "nat", "-A", "POSTROUTING",
            "-s", f"{CONTAINER_IP}/32",
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "MASQUERADE"
        ],
        description=f"POSTROUTING MASQUERADE for {CONTAINER_IP}/32"
    )


def update_pccs_url():
    """Update PCCS URL in QCNL configuration."""
    qcnl_conf = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs/etc/sgx_default_qcnl.conf")
    qcnl_conf_bak = Path(f"{qcnl_conf}.bak")

    host_ip = get_bridge_ip(BRIDGE_NAME)

    pccs_url = f"https://{host_ip}:{PCCS_PORT}/sgx/certification/v4/"

    if not qcnl_conf.exists():
        log(LogLevel.ERROR, f"Error: {qcnl_conf} not found")
        sys.exit(1)

    if not qcnl_conf_bak.exists():
        shutil.copy(qcnl_conf, qcnl_conf_bak)

    shutil.copy(qcnl_conf_bak, qcnl_conf)

    with open(qcnl_conf, "r", encoding="utf-8") as file:
        content = file.read()

    content = re.sub(
        r'"pccs_url":\s*"[^"]*"',
        f'"pccs_url": "{pccs_url}"',
        content
    )

    with open(qcnl_conf, "w", encoding="utf-8") as file:
        file.write(content)



def init_container():
    """Initialize LXC container for PKI Authority."""
    LXCContainer(PKI_SERVICE_NAME).create()


def get_node_tunnel_ip(node_id: str, wg_props: List[dict]) -> Optional[str]:
    """Get tunnel IP for a node from WireGuard properties."""
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def save_property_into_fs(file_name: str, content: bytes):
    """Save property content to filesystem."""
    STORAGE_PATH.mkdir(parents=True, exist_ok=True)
    file_path = STORAGE_PATH / file_name
    file_path.write_bytes(content)


def read_property_from_fs(file_name: str) -> tuple[bool, bytes]:
    """Read property content from filesystem."""
    file_path = STORAGE_PATH / file_name
    if file_path.exists():
        content = file_path.read_bytes()
        if content:
            return (True, content)
    return (False, b"")


