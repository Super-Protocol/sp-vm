#!/usr/bin/env python3
"""
PKI Authority container management helpers (Podman).
"""

import json
import re
import secrets
import subprocess
import sys
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import List

import yaml
from cryptography import x509
from cryptography.x509.oid import ObjectIdentifier

PKI_SERVICE_NAME = "pki-authority"
PKI_POD_NAME = "tee"
PKI_CONTAINER_NAME = f"{PKI_POD_NAME}-{PKI_SERVICE_NAME}"
PCCS_PORT = "8081"
PKI_SERVICE_EXTERNAL_PORT = "8443"
PKI_CONTAINER_HTTPS_PORT = "443"
PKI_CONTAINER_HTTP_PORT = "80"
SWARM_ENV_YAML = "/sp/swarm/swarm-env.yaml"
SWARM_KEY_FILE = "/etc/swarm/swarm.key"
PODMAN_NETWORK_NAME = "podman"
IPTABLES_RULE_COMMENT = "pki-authority-rule"

# Base directory for all PKI authority data
BASE_DIR = Path("/etc/pki-authority")
STORAGE_PATH = BASE_DIR / "swarm-storage"
POD_YAML_PATH = BASE_DIR / "pod.yaml"
APP_CONFIG_PATH = BASE_DIR / "app-config.yaml"
QCNL_CONF_PATH = BASE_DIR / "sgx_default_qcnl.conf"

# Template config path
TEMPLATE_YAML = Path("/etc/super/containers/pki-authority/pki-authority-template.yaml")

# VM certs
VM_CERTS_HOST_DIR = "/etc/super/certs/vm"
VM_CERTS_CONTAINER_DIR = "/app/vm-certs"
VM_CERT_FILE_NAME = "vm_cert.pem"
VM_CERT_CONTAINER_FILE = f"{VM_CERTS_CONTAINER_DIR}/{VM_CERT_FILE_NAME}"

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
    """Detect network type from kernel command line."""
    try:
        with open("/proc/cmdline", "r", encoding="utf-8") as file:
            cmdline = file.read()

        if "allow_untrusted=true" in cmdline:
            return NetworkType.UNTRUSTED
        return NetworkType.TRUSTED
    except FileNotFoundError:
        return NetworkType.TRUSTED


def read_network_type_from_certificate(cert_path: Path = STORAGE_PATH / "basic_certificate") -> NetworkType:
    """Read network type from certificate's custom OID extension."""
    try:
        if not cert_path.exists():
            error_msg = f"Certificate not found at {cert_path}"
            log(LogLevel.ERROR, error_msg)
            raise FileNotFoundError(error_msg)

        with open(cert_path, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())

        network_type_oid = ObjectIdentifier(OID_CUSTOM_EXTENSION_NETWORK_TYPE)

        try:
            extension = cert.extensions.get_extension_for_oid(network_type_oid)
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


def get_pki_authority_param(param_name: str) -> str:
    """Read PKI authority parameter from swarm-env.yaml."""
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
    except Exception as error:
        error_msg = f"Failed to read {param_name} from {SWARM_ENV_YAML}: {error}"
        log(LogLevel.ERROR, error_msg)
        raise Exception(error_msg) from error


def generate_swarm_key() -> str:
    """Generate new 32-byte swarm key and save to file."""
    swarm_key_path = Path(SWARM_KEY_FILE)

    log(LogLevel.INFO, "Generating new 32-byte swarm key")
    swarm_key = secrets.token_hex(32)

    try:
        if not swarm_key_path.parent.exists():
            swarm_key_path.parent.mkdir(parents=True, exist_ok=True)
            log(LogLevel.INFO, f"Created directory {swarm_key_path.parent}")

        with open(swarm_key_path, "w", encoding="utf-8") as file:
            file.write(swarm_key)

        swarm_key_path.chmod(0o600)

        log(LogLevel.INFO, f"Swarm key generated and saved to {SWARM_KEY_FILE}")
        return swarm_key
    except Exception as error:
        error_msg = f"Failed to save swarm key: {error}"
        log(LogLevel.ERROR, error_msg)
        raise Exception(error_msg) from error


def load_swarm_key() -> str:
    """Load existing swarm key from file."""
    swarm_key_path = Path(SWARM_KEY_FILE)

    if not swarm_key_path.exists():
        error_msg = f"Swarm key file {SWARM_KEY_FILE} not found"
        log(LogLevel.ERROR, error_msg)
        raise FileNotFoundError(error_msg)

    log(LogLevel.INFO, f"Reading swarm key from {SWARM_KEY_FILE}")

    try:
        with open(swarm_key_path, "r", encoding="utf-8") as file:
            swarm_key = file.read().strip()

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
    """Patch application YAML config and write to runtime directory."""
    if not TEMPLATE_YAML.exists():
        log(LogLevel.ERROR, f"Error: {TEMPLATE_YAML} not found.")
        sys.exit(1)

    with open(TEMPLATE_YAML, "r", encoding="utf-8") as file:
        config = yaml.safe_load(file)

    # Set the CPU type in the configuration
    if "pki" not in config:
        config["pki"] = {}
    if "ownChallenge" not in config["pki"]:
        config["pki"]["ownChallenge"] = {}
    config["pki"]["ownChallenge"]["type"] = cpu_type

    # For untrusted, generate random deviceIdHex (32 bytes)
    if cpu_type == "untrusted":
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

    # Set vmCertificatePath for swarm-normal mode
    if vm_mode == VMMode.SWARM_NORMAL:
        config["pki"]["mode"]["vmCertificatePath"] = VM_CERT_CONTAINER_FILE
        log(LogLevel.INFO, f"Set vmCertificatePath to: {VM_CERT_CONTAINER_FILE}")

    BASE_DIR.mkdir(parents=True, exist_ok=True)

    with open(APP_CONFIG_PATH, "w", encoding="utf-8") as file:
        yaml.dump(config, file, default_flow_style=False)

    log(LogLevel.INFO, f"Application config written to {APP_CONFIG_PATH}")


def _extract_qcnl_template_from_image(image: str, dst_path: Path) -> bool:
    """Extract /etc/sgx_default_qcnl.conf from image to dst_path.

    Returns True on success, False if extraction failed.
    """
    container_name = f"{PKI_SERVICE_NAME}-qcnl-extract"

    # Best effort cleanup in case a stale temp container exists.
    subprocess.run(
        ["podman", "rm", "-f", container_name],
        capture_output=True,
        text=True,
        check=False,
    )

    try:
        create_result = subprocess.run(
            ["podman", "create", "--name", container_name, image],
            capture_output=True,
            text=True,
            check=False,
        )
        if create_result.returncode != 0:
            log(LogLevel.WARN, f"Failed to create temp container for QCNL extraction: {create_result.stderr.strip()}")
            return False

        cp_result = subprocess.run(
            ["podman", "cp", f"{container_name}:/etc/sgx_default_qcnl.conf", str(dst_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if cp_result.returncode != 0:
            log(LogLevel.WARN, f"Failed to copy QCNL config from image: {cp_result.stderr.strip()}")
            return False

        log(LogLevel.INFO, f"Extracted QCNL template from image {image}")
        return True
    finally:
        subprocess.run(
            ["podman", "rm", "-f", container_name],
            capture_output=True,
            text=True,
            check=False,
        )


def generate_qcnl_conf(pccs_addr: str, image: str):
    """Generate QCNL configuration with PCCS URL pointing to host.

    Args:
        pccs_addr: PCCS address as ip:port string.
        image: Container image to extract QCNL template from.
    """
    pccs_url = f"https://{pccs_addr}/sgx/certification/v4/"

    BASE_DIR.mkdir(parents=True, exist_ok=True)

    if _extract_qcnl_template_from_image(image=image, dst_path=QCNL_CONF_PATH):
        with open(QCNL_CONF_PATH, "r", encoding="utf-8") as file:
            content = file.read()
    else:
        log(LogLevel.ERROR, f"QCNL template not found in image: {image}:/etc/sgx_default_qcnl.conf")
        sys.exit(1)

    content = re.sub(
        r'"pccs_url":\s*"[^"]*"',
        f'"pccs_url": "{pccs_url}"',
        content
    )

    with open(QCNL_CONF_PATH, "w", encoding="utf-8") as file:
        file.write(content)

    log(LogLevel.INFO, f"QCNL config written to {QCNL_CONF_PATH} with PCCS URL {pccs_url}")


def get_podman_network_info() -> dict:
    """Get gateway IP and bridge interface name from podman network inspect.

    Returns dict with 'gateway' and 'bridge' keys.
    """
    try:
        result = subprocess.run(
            ["podman", "network", "inspect", PODMAN_NETWORK_NAME],
            capture_output=True, text=True, check=True
        )
        networks = json.loads(result.stdout)
        if networks and isinstance(networks, list):
            net = networks[0]
            bridge = net.get("network_interface", "podman0")
            for subnet in net.get("subnets", []):
                gw = subnet.get("gateway")
                if gw:
                    log(LogLevel.INFO, f"Podman network: gateway={gw}, bridge={bridge}")
                    return {"gateway": gw, "bridge": bridge}
    except Exception as error:
        log(LogLevel.WARN, f"Failed to get info from podman network inspect: {error}")

    log(LogLevel.ERROR, "Could not determine podman network gateway")
    sys.exit(1)


def _ensure_iptables_rule(check_args: List[str], add_args: List[str], description: str):
    """Idempotently add an iptables rule (check with -C, add with -A)."""
    log(LogLevel.INFO, f"Checking iptables rule: {description}")
    check_result = subprocess.run(check_args, capture_output=True, check=False)
    if check_result.returncode == 0:
        log(LogLevel.INFO, "Rule already exists")
    else:
        subprocess.run(add_args, check=True)
        log(LogLevel.INFO, "Rule added")


def setup_pccs_iptables() -> str:
    """Setup iptables DNAT so the podman container can reach PCCS on localhost.

    Returns the PCCS address as ip:port string.
    """
    net_info = get_podman_network_info()
    bridge_ip = net_info["gateway"]

    # DNAT: packets from container to bridge_ip:PCCS_PORT -> 127.0.0.1:PCCS_PORT
    common_args = [
        "-t", "nat",
        "-p", "tcp",
        "-d", bridge_ip,
        "--dport", PCCS_PORT,
        "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
        "-j", "DNAT",
        "--to-destination", f"127.0.0.1:{PCCS_PORT}"
    ]
    _ensure_iptables_rule(
        check_args=["iptables"] + ["-C", "PREROUTING"] + common_args,
        add_args=["iptables"] + ["-A", "PREROUTING"] + common_args,
        description=f"PCCS DNAT {bridge_ip}:{PCCS_PORT} -> 127.0.0.1:{PCCS_PORT}"
    )

    # Allow DNAT'd packets to reach localhost (INPUT chain may drop them)
    input_args = [
        "-p", "tcp",
        "-d", "127.0.0.1",
        "--dport", PCCS_PORT,
        "-m", "comment", "--comment", IPTABLES_RULE_COMMENT,
        "-j", "ACCEPT",
    ]
    _ensure_iptables_rule(
        check_args=["iptables", "-C", "INPUT"] + input_args,
        add_args=["iptables", "-I", "INPUT"] + input_args,
        description=f"PCCS INPUT ACCEPT 127.0.0.1:{PCCS_PORT}"
    )

    return f"{bridge_ip}:{PCCS_PORT}"


def delete_pccs_iptables():
    """Delete all iptables rules tagged with pki-authority-rule comment."""
    for chain in ["PREROUTING", "OUTPUT", "POSTROUTING"]:
        result = subprocess.run(
            ["iptables", "-t", "nat", "-S", chain],
            capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            continue
        for rule in result.stdout.splitlines():
            if IPTABLES_RULE_COMMENT in rule:
                delete_rule = rule.replace("-A", "-D", 1)
                subprocess.run(
                    ["iptables", "-t", "nat"] + delete_rule.split()[1:],
                    check=True
                )
                log(LogLevel.INFO, f"Deleted iptables rule: {delete_rule}")

    # Clean up INPUT rules
    result = subprocess.run(
        ["iptables", "-S", "INPUT"],
        capture_output=True, text=True, check=False
    )
    if result.returncode == 0:
        for rule in result.stdout.splitlines():
            if IPTABLES_RULE_COMMENT in rule:
                delete_rule = rule.replace("-A", "-D", 1)
                subprocess.run(
                    ["iptables"] + delete_rule.split()[1:],
                    check=True
                )
                log(LogLevel.INFO, f"Deleted iptables rule: {delete_rule}")


def generate_pod_yaml(cpu_type: str, vm_mode: VMMode, image: str):
    """Generate Kubernetes Pod YAML for podman play kube."""
    volumes = [
        {
            "name": "app-config",
            "hostPath": {"path": str(APP_CONFIG_PATH), "type": "File"}
        },
        {
            "name": "swarm-storage",
            "hostPath": {"path": str(STORAGE_PATH), "type": "DirectoryOrCreate"}
        },
        {
            "name": "qcnl-conf",
            "hostPath": {"path": str(QCNL_CONF_PATH), "type": "File"}
        },
    ]

    volume_mounts = [
        {"name": "app-config", "mountPath": "/app/conf/swarm.yaml", "readOnly": True},
        {"name": "swarm-storage", "mountPath": "/app/swarm-storage"},
        {"name": "qcnl-conf", "mountPath": "/etc/sgx_default_qcnl.conf", "readOnly": True},
    ]

    # VM certs mount (swarm-normal mode only)
    if vm_mode == VMMode.SWARM_NORMAL:
        volumes.append({
            "name": "vm-certs",
            "hostPath": {"path": VM_CERTS_HOST_DIR, "type": "Directory"}
        })
        volume_mounts.append({
            "name": "vm-certs",
            "mountPath": VM_CERTS_CONTAINER_DIR,
            "readOnly": True
        })

    # Device passthrough for TEE attestation
    annotations = {}
    if cpu_type == "tdx":
        annotations["io.podman.annotations.device"] = "/dev/tdx_guest"
        if Path("/etc/tdx-attest.conf").exists():
            volumes.append({
                "name": "tdx-attest-conf",
                "hostPath": {"path": "/etc/tdx-attest.conf", "type": "File"}
            })
            volume_mounts.append({
                "name": "tdx-attest-conf",
                "mountPath": "/etc/tdx-attest.conf",
                "readOnly": True
            })
    elif cpu_type == "sev-snp":
        annotations["io.podman.annotations.device"] = "/dev/sev-guest"

    pod_spec = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": PKI_POD_NAME,
            "labels": {"app": PKI_SERVICE_NAME},
        },
        "spec": {
            "containers": [
                {
                    "name": PKI_SERVICE_NAME,
                    "image": image,
                    "env": [
                        {
                            "name": "CONFIG_CHAIN",
                            "value": "prod.sgx,subroot,nvidia,sev-snp,swarm"
                        },
                    ],
                    "ports": [
                        {
                            "containerPort": int(PKI_CONTAINER_HTTPS_PORT),
                            "hostPort": int(PKI_SERVICE_EXTERNAL_PORT),
                            "protocol": "TCP"
                        },
                        {
                            "containerPort": int(PKI_CONTAINER_HTTP_PORT),
                            "hostPort": int(PKI_CONTAINER_HTTP_PORT),
                            "protocol": "TCP"
                        },
                    ],
                    "volumeMounts": volume_mounts,
                    "securityContext": {"privileged": True},
                }
            ],
            "volumes": volumes,
            "restartPolicy": "Always",
        }
    }

    if annotations:
        pod_spec["metadata"]["annotations"] = annotations

    BASE_DIR.mkdir(parents=True, exist_ok=True)

    with open(POD_YAML_PATH, "w", encoding="utf-8") as file:
        yaml.dump(pod_spec, file, default_flow_style=False)

    log(LogLevel.INFO, f"Pod YAML written to {POD_YAML_PATH}")


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
