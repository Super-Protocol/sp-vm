#!/usr/bin/env python3
"""
PKI Authority LXC container management helpers.
"""

import os
import re
import secrets
import shutil
import subprocess
import sys
import urllib.request
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import List, Optional

import yaml
from cryptography import x509
from cryptography.x509.oid import ObjectIdentifier

PKI_SERVICE_NAME = "pki-authority"
SERVICE_INSIDE_CONTAINER = "tee-pki"
BRIDGE_NAME = "lxcbr0"
PCCS_PORT = "8081"
PKI_SERVICE_EXTERNAL_PORT = "8443"
CONTAINER_IP = "10.0.3.100"
WIREGUARD_INTERFACE = "wg0"
EXTERNAL_INTERFACE = "enp0s1"  # Default external network interface
CONTAINER_ROOTFS = f"/var/lib/lxc/{PKI_SERVICE_NAME}/rootfs"
STORAGE_PATH = Path(f"{CONTAINER_ROOTFS}/app/swarm-storage")
IPTABLES_RULE_COMMENT = f"{PKI_SERVICE_NAME}-rule"
SWARM_ENV_YAML = "/sp/swarm/swarm-env.yaml"
VM_CERTS_HOST_DIR = "/etc/super/certs/vm"
VM_CERTS_CONTAINER_DIR = "app/vm-certs"  # Relative path for lxc.mount.entry
VM_CERT_FILE_NAME = "vm_cert.pem"
VM_CERT_CONTAINER_FILE = f"/{VM_CERTS_CONTAINER_DIR}/{VM_CERT_FILE_NAME}"
SWARM_KEY_FILE = "/etc/swarm/swarm.key"
OID_CUSTOM_EXTENSION_NETWORK_TYPE = "1.3.6.1.3.8888.4"


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
    SWARM_INIT = "swarm-init"
    SWARM_NORMAL = "swarm-normal"


class NetworkType(Enum):
    """Network type types."""
    TRUSTED = "trusted"
    UNTRUSTED = "untrusted"


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

    def is_service_healthy(self, healthcheck_url: str = "/healthcheck") -> bool:
        """Check if service inside container is running and healthy."""
        try:
            # Check service status inside container
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

            if status != "active":
                log(LogLevel.INFO, f"Service {SERVICE_INSIDE_CONTAINER} status: {status}")
                return False

            # Service is active, check healthcheck endpoint
            container_ip = self.get_ip()
            if not container_ip:
                log(LogLevel.INFO, "Could not get container IP")
                return False

            # Perform HTTP healthcheck
            try:
                req = urllib.request.Request(f"http://{container_ip}{healthcheck_url}")
                with urllib.request.urlopen(req, timeout=5) as response:
                    if response.status == 200:
                        return True

                    log(
                        LogLevel.INFO,
                        f"Healthcheck returned status: {response.status}"
                    )
                    return False
            except Exception as error:  # pylint: disable=broad-exception-caught
                log(LogLevel.INFO, f"Healthcheck failed: {error}")
                return False

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

        if "vm_mode=swarm-init" in cmdline:
            return VMMode.SWARM_INIT
        return VMMode.SWARM_NORMAL
    except FileNotFoundError:
        return VMMode.SWARM_NORMAL


def detect_network_type() -> NetworkType:
    """Detect network type from kernel command line.

    Returns:
        NetworkType.UNTRUSTED if allow_untrusted=true is present in cmdline,
        otherwise NetworkType.TRUSTED.
    """
    try:
        with open("/proc/cmdline", "r", encoding="utf-8") as file:
            cmdline = file.read()

        if "allow_untrusted=true" in cmdline:
            return NetworkType.UNTRUSTED
        return NetworkType.TRUSTED
    except FileNotFoundError:
        return NetworkType.TRUSTED


def read_network_type_from_certificate(cert_path: Path = STORAGE_PATH / "basic_certificate") -> NetworkType:
    """Read network type from certificate's custom OID extension.
    
    Args:
        cert_path: Path to PEM certificate file.
    
    Returns:
        NetworkType.TRUSTED or NetworkType.UNTRUSTED based on the value of the
        custom extension identified by OID_CUSTOM_EXTENSION_NETWORK_TYPE.
        Defaults to NetworkType.TRUSTED if the extension is not present or has
        another value.
    """
    try:
        if not cert_path.exists():
            error_msg = f"Certificate not found at {cert_path}"
            log(LogLevel.ERROR, error_msg)
            raise FileNotFoundError(error_msg)
        
        with open(cert_path, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())
        
        # Custom OID for network type
        network_type_oid = ObjectIdentifier(OID_CUSTOM_EXTENSION_NETWORK_TYPE)
        
        try:
            # Try to get the extension by OID
            extension = cert.extensions.get_extension_for_oid(network_type_oid)
            # Extension value is typically ASN.1 encoded, get raw value
            value = extension.value.value.decode('utf-8').strip()
            
            if value == NetworkType.TRUSTED.value:
                log(LogLevel.INFO, f"Network type from certificate OID: {value}")
                return NetworkType.TRUSTED
            elif value == NetworkType.UNTRUSTED.value:
                log(LogLevel.INFO, f"Network type from certificate OID: {value}")
                return NetworkType.UNTRUSTED
            else:
                log(LogLevel.WARN, f"Unknown network type value '{value}' in OID, defaulting to trusted")
                return NetworkType.TRUSTED
                
        except x509.ExtensionNotFound:
            log(LogLevel.INFO, f"OID {OID_CUSTOM_EXTENSION_NETWORK_TYPE} not found in certificate, defaulting to trusted")
            return NetworkType.TRUSTED
            
    except Exception as e:
        log(LogLevel.ERROR, f"Error reading certificate: {e}, defaulting to trusted")
        return NetworkType.TRUSTED


def read_yaml_config_param(param_path: str) -> Optional[str]:
    """Read parameter from container's yaml configuration.

    Args:
        param_path: Dot-separated path to parameter (e.g., 'pki.ownDomain').

    Returns:
        Parameter value as string, or None if not found or error.
    """
    yaml_config_path = Path(f"{CONTAINER_ROOTFS}/app/conf/lxc.yaml")

    if not yaml_config_path.exists():
        log(LogLevel.DEBUG, f"YAML config not found: {yaml_config_path}")
        return None

    try:
        with open(yaml_config_path, "r", encoding="utf-8") as file:
            config = yaml.safe_load(file)

        if not config:
            log(LogLevel.DEBUG, f"Empty YAML config: {yaml_config_path}")
            return None

        # Navigate through nested dictionary using dot-separated path
        value = config
        for key in param_path.split('.'):
            if isinstance(value, dict):
                value = value.get(key)
                if value is None:
                    return None
            else:
                return None

        return str(value) if value is not None else None

    except Exception as error:  # pylint: disable=broad-exception-caught
        log(LogLevel.DEBUG, f"Failed to read {param_path} from YAML config: {error}")
        return None


def get_pki_authority_param(param_name: str) -> str:
    """Read PKI authority parameter from swarm-env.yaml.

    Args:
        param_name: Name of the parameter under pki-authority section.

    Returns:
        Parameter value as string.

    Raises:
        FileNotFoundError: If swarm-env.yaml does not exist.
        ValueError: If configuration is empty or parameter is not found.
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

        param_value = config.get("pki-authority", {}).get(param_name)
        if not param_value:
            error_msg = (
                f"No {param_name} found in {SWARM_ENV_YAML} "
                f"under pki-authority.{param_name}"
            )
            log(LogLevel.ERROR, error_msg)
            raise ValueError(error_msg)

        log(LogLevel.INFO, f"Read {param_name} from config: {param_value}")
        return param_value

    except (FileNotFoundError, ValueError):
        raise
    except Exception as error:  # pylint: disable=broad-exception-caught
        error_msg = f"Failed to read {param_name} from {SWARM_ENV_YAML}: {error}"
        log(LogLevel.ERROR, error_msg)
        raise Exception(error_msg) from error


def generate_swarm_key() -> str:
    """Generate new 32-byte swarm key and save to file.
    
    Returns:
        Swarm key as hex string (64 characters).
        
    Raises:
        Exception: If failed to save key to file.
    """
    swarm_key_path = Path(SWARM_KEY_FILE)
    
    log(LogLevel.INFO, "Generating new 32-byte swarm key")
    swarm_key = secrets.token_hex(32)  # 32 bytes = 64 hex characters
    
    try:
        # Ensure directory exists
        if not swarm_key_path.parent.exists():
            swarm_key_path.parent.mkdir(parents=True, exist_ok=True)
            log(LogLevel.INFO, f"Created directory {swarm_key_path.parent}")
        
        with open(swarm_key_path, "w", encoding="utf-8") as file:
            file.write(swarm_key)
        
        # Set restrictive permissions (600)
        swarm_key_path.chmod(0o600)
        
        log(LogLevel.INFO, f"Swarm key generated and saved to {SWARM_KEY_FILE}")
        return swarm_key
    except Exception as error:
        error_msg = f"Failed to save swarm key: {error}"
        log(LogLevel.ERROR, error_msg)
        raise Exception(error_msg) from error


def load_swarm_key() -> str:
    """Load existing swarm key from file.
    
    Returns:
        Swarm key as hex string (64 characters).
        
    Raises:
        FileNotFoundError: If swarm key file doesn't exist.
        ValueError: If swarm key format is invalid.
        Exception: For other errors during reading.
    """
    swarm_key_path = Path(SWARM_KEY_FILE)
    
    if not swarm_key_path.exists():
        error_msg = f"Swarm key file {SWARM_KEY_FILE} not found"
        log(LogLevel.ERROR, error_msg)
        raise FileNotFoundError(error_msg)
    
    log(LogLevel.INFO, f"Reading swarm key from {SWARM_KEY_FILE}")
    
    try:
        with open(swarm_key_path, "r", encoding="utf-8") as file:
            swarm_key = file.read().strip()
        
        # Validate key format (should be 64 hex characters)
        if not re.match(r'^[0-9a-fA-F]{64}$', swarm_key):
            error_msg = f"Invalid swarm key format in {SWARM_KEY_FILE}. Expected 64 hex characters."
            log(LogLevel.ERROR, error_msg)
            raise ValueError(error_msg)
        
        log(LogLevel.INFO, "Swarm key loaded successfully")
        return swarm_key
    except (FileNotFoundError, ValueError):
        raise
    except Exception as error:
        error_msg = f"Failed to read swarm key: {error}"
        log(LogLevel.ERROR, error_msg)
        raise Exception(error_msg) from error


def patch_yaml_config(
    cpu_type: str,
    vm_mode: VMMode,
    pki_domain: str,
    network_type: NetworkType,
    network_id: str,
    swarm_key: str
):
    """Set own challenge type in LXC container configuration."""
    template_name = "lxc-swarm-template.yaml"
    log(
        LogLevel.INFO,
        f"Detected {vm_mode.value} mode, using swarm template"
    )

    src_yaml = Path(f"/etc/super/containers/pki-authority/{template_name}")
    dst_yaml = Path(f"{CONTAINER_ROOTFS}/app/conf/lxc.yaml")

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

    # For untrusted, generate random deviceIdHex (32 bytes)
    if cpu_type == "untrusted":
        # Check if untrusted CPU type is running in trusted network
        if network_type != NetworkType.UNTRUSTED:
            error_msg = (
                "Cannot run untrusted machine in trusted network. "
                f"CPU type: {cpu_type}, Network type: {network_type.value}"
            )
            log(LogLevel.ERROR, error_msg)
            raise ValueError(error_msg)

        device_id_hex = secrets.token_hex(32)
        config["pki"]["ownChallenge"]["deviceIdHex"] = device_id_hex
        log(LogLevel.INFO, f"Generated deviceIdHex for untrusted type: {device_id_hex}")

    # Add 'untrusted' to allowedChallenges if network type is untrusted
    if network_type == NetworkType.UNTRUSTED:
        if "allowedChallenges" not in config["pki"]:
            config["pki"]["allowedChallenges"] = []
        if "untrusted" not in config["pki"]["allowedChallenges"]:
            config["pki"]["allowedChallenges"].append("untrusted")
            log(LogLevel.INFO, "Added 'untrusted' to allowedChallenges")

    # Set ownDomain from parameter
    if pki_domain:
        config["pki"]["ownDomain"] = pki_domain
        log(LogLevel.INFO, f"Set ownDomain to: {pki_domain}")

    # Set mode.swarmMode
    if "mode" not in config["pki"]:
        config["pki"]["mode"] = {}

    mode_value = "init" if vm_mode == VMMode.SWARM_INIT else "normal"
    config["pki"]["mode"]["swarmMode"] = mode_value
    log(LogLevel.INFO, f"Set swarmMode to: {mode_value}")

    # Set networkSettings
    if network_type or network_id:
        if "networkSettings" not in config["pki"]["mode"]:
            config["pki"]["mode"]["networkSettings"] = {}
        
        if network_type:
            config["pki"]["mode"]["networkSettings"]["networkType"] = network_type.value
            log(LogLevel.INFO, f"Set networkSettings.networkType: {network_type.value}")
        
        if network_id:
            config["pki"]["mode"]["networkSettings"]["networkID"] = network_id
            log(LogLevel.INFO, f"Set networkSettings.networkID: {network_id}")

    # Set secretsStorage with swarmKey
    if swarm_key:
        if "secretsStorage" not in config:
            config["secretsStorage"] = {}
        if "static" not in config["secretsStorage"]:
            config["secretsStorage"]["static"] = {}
        config["secretsStorage"]["static"]["swarmKey"] = swarm_key
        log(LogLevel.INFO, "Set swarmKey in secretsStorage.static")

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

def mount_vm_certs():
    """Mount vm certs directory into container and patch YAML config with vmCertificatePath."""
    src_dir = Path(VM_CERTS_HOST_DIR)
    if not src_dir.exists():
        log(LogLevel.ERROR, f"Error: {src_dir} not found")
        sys.exit(1)

    # Add mount entry to LXC config
    config_file = Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}/config")
    mount_entry = f"lxc.mount.entry = {VM_CERTS_HOST_DIR} {VM_CERTS_CONTAINER_DIR} none bind,ro,create=dir\n"
    
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as file:
            content = file.read()
        
        if mount_entry.strip() not in content:
            with open(config_file, "a", encoding="utf-8") as file:
                file.write(mount_entry)
            log(LogLevel.INFO, f"Added mount entry for {VM_CERTS_HOST_DIR}")
        else:
            log(LogLevel.INFO, f"Mount entry for {VM_CERTS_HOST_DIR} already exists")
    else:
        log(LogLevel.ERROR, f"Error: LXC config file {config_file} not found")
        sys.exit(1)

    # Update YAML config with vmCertificatePath
    dst_yaml = Path(f"{CONTAINER_ROOTFS}/app/conf/lxc.yaml")

    if not dst_yaml.exists():
        log(LogLevel.ERROR, f"Error: {dst_yaml} not found")
        sys.exit(1)

    with open(dst_yaml, "r", encoding="utf-8") as file:
        config = yaml.safe_load(file)

    if not config:
        log(LogLevel.ERROR, f"Empty YAML config: {dst_yaml}")
        sys.exit(1)

    if "pki" not in config:
        config["pki"] = {}
    if "mode" not in config["pki"]:
        config["pki"]["mode"] = {}

    config["pki"]["mode"]["vmCertificatePath"] = VM_CERT_CONTAINER_FILE
    log(LogLevel.INFO, f"Set vmCertificatePath to: {VM_CERT_CONTAINER_FILE}")

    with open(dst_yaml, "w", encoding="utf-8") as file:
        yaml.dump(config, file, default_flow_style=False)


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


def get_external_interface() -> str:
    """Detect external network interface from default route.
    
    Returns:
        Name of the external network interface used for default route.
        Falls back to EXTERNAL_INTERFACE constant if detection fails.
    """
    try:
        # Get default route interface
        result = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True,
            text=True,
            check=False
        )
        
        if result.returncode == 0 and result.stdout:
            # Parse output like: "default via 192.168.1.1 dev enp0s1 proto dhcp metric 100"
            match = re.search(r'dev\s+(\S+)', result.stdout)
            if match:
                interface = match.group(1)
                log(LogLevel.INFO, f"Detected external interface from default route: {interface}")
                return interface
        
        log(LogLevel.WARN, f"Could not detect external interface, using default: {EXTERNAL_INTERFACE}")
        return EXTERNAL_INTERFACE
    except Exception as error:  # pylint: disable=broad-exception-caught
        log(LogLevel.WARN, f"Failed to detect external interface: {error}, using default: {EXTERNAL_INTERFACE}")
        return EXTERNAL_INTERFACE


def delete_iptables_rules():
    """Delete all iptables rules for PKI container (NAT and filter tables)."""
    # Delete rules from NAT table chains: PREROUTING, OUTPUT, POSTROUTING
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
                log(LogLevel.INFO, f"Deleted iptables NAT rule: {delete_rule}")

    # Delete rules from filter table (INPUT chain)
    result = subprocess.run(
        ["iptables", "-S", "INPUT"],
        capture_output=True, text=True, check=True
    )

    rules = result.stdout.splitlines()

    for rule in rules:
        # Delete rules that contain our comment
        if IPTABLES_RULE_COMMENT in rule:
            delete_rule = rule.replace("-A", "-D", 1)
            subprocess.run(["iptables"] + delete_rule.split()[1:], check=True)
            log(LogLevel.INFO, f"Deleted iptables INPUT rule: {delete_rule}")


def ensure_iptables_rule(check_args: List[str], add_args: List[str], description: str):
    """Ensure iptables rule exists, add if missing."""
    log(LogLevel.INFO, f"Checking iptables rule: {description}")

    check_result = subprocess.run(check_args, capture_output=True, check=False)

    if check_result.returncode == 0:
        log(LogLevel.INFO, "Rule already exists")
    else:
        subprocess.run(add_args, check=True)
        log(LogLevel.INFO, "Rule added")

def setup_iptables():
    """Setup iptables NAT rules for LXC container access to host services."""
    host_ip = get_bridge_ip(BRIDGE_NAME)
    external_interface = get_external_interface()

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

    # Rule 2: MASQUERADE
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

    # Rule 3: Allow port 8081 on lxcbr0
    ensure_iptables_rule(
        check_args=[
            "iptables", "-C", "INPUT",
            "-i", "lxcbr0",
            "-p", "tcp",
            "--dport", "8081",
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "ACCEPT"
        ],
        add_args=[
            "iptables", "-A", "INPUT",
            "-i", "lxcbr0",
            "-p", "tcp",
            "--dport", "8081",
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "ACCEPT"
        ],
        description="Allow TCP port 8081 on lxcbr0"
    )

    # Rule 4: DNAT external port 8443 to container port 443
    ensure_iptables_rule(
        check_args=[
            "iptables", "-t", "nat", "-C", "PREROUTING",
            "-i", external_interface,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        add_args=[
            "iptables", "-t", "nat", "-A", "PREROUTING",
            "-i", external_interface,
            "-p", "tcp",
            "--dport", PKI_SERVICE_EXTERNAL_PORT,
            "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
            "-j", "DNAT",
            "--to-destination", f"{CONTAINER_IP}:443"
        ],
        description=f"PKI external access: {external_interface}:{PKI_SERVICE_EXTERNAL_PORT} -> {CONTAINER_IP}:443"
    )


def update_pccs_url():
    """Update PCCS URL in QCNL configuration."""
    qcnl_conf = Path(f"{CONTAINER_ROOTFS}/etc/sgx_default_qcnl.conf")
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
