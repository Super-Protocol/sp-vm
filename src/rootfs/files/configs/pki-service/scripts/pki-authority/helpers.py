#!/usr/bin/env python3
"""Helpers for PKI Authority provisioning plugin."""

import hashlib
import os
import re
import subprocess
import sys
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml
from cryptography import x509
from cryptography.x509.oid import ObjectIdentifier


# ---------------------------------------------------------------------------
# Path / port constants
# ---------------------------------------------------------------------------

PKI_SERVICE_NAME = "pki-authority"

BASE_DIR = Path("/etc/pki-authority")
STORAGE_PATH = BASE_DIR / "swarm-storage"
APP_CONFIG_PATH = BASE_DIR / "app-config.yaml"
TEMPLATE_YAML = Path(__file__).parent / "pki-authority-template.yaml"

SWARM_ENV_YAML = "/sp/swarm/swarm-env.yaml"
SWARM_KEY_FILE = "/etc/swarm/swarm.key"

OID_CUSTOM_EXTENSION_NETWORK_TYPE = "1.3.6.1.3.8888.4"

PKI_API_HTTP_PORT = 8000
PKI_API_HTTPS_PORT = 9443
CONFIG_CHAIN = "swarm,nvidia,sev-snp"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

class LogLevel(Enum):
    INFO = "INFO"
    WARN = "WARN"
    ERROR = "ERROR"
    DEBUG = "DEBUG"


def log(level: LogLevel, message: str):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{PKI_SERVICE_NAME}] [{level.value}] {message}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class NetworkType(Enum):
    TRUSTED = "trusted"
    UNTRUSTED = "untrusted"


# ---------------------------------------------------------------------------
# Certificate / swarm helpers
# ---------------------------------------------------------------------------

def read_network_type_from_certificate(cert_path: Path = STORAGE_PATH / "basic_ca.pem") -> NetworkType:
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


# ---------------------------------------------------------------------------
# Image constants
# ---------------------------------------------------------------------------

PKI_AUTHORITY_IMAGE_REGISTRY = "ghcr.io"
PKI_AUTHORITY_IMAGE_REPO = "super-protocol/tee-pki-authority-service"
DEFAULT_PKI_AUTHORITY_IMAGE_TAG = "build-22734492513"

# ---------------------------------------------------------------------------
# Container / plugin constants
# ---------------------------------------------------------------------------

SERVICE_UNIT = "pki-authority.service"
SERVICE_ENV_FILE = BASE_DIR / "env"
NODE_READY_PROPERTY = "pki_authority_node_ready"

# Mapping: swarmSecrets id → filename in STORAGE_PATH
SECRETS_MAP: Dict[str, str] = {
    "pki_root_basic_cert": "basic_ca.pem",
    "pki_root_lite_cert": "lite_ca.pem",
    "pki_subroot_device_basic_cert": "basic_cert.pem",
    "pki_subroot_device_basic_key": "basic_key.pem",
    "pki_subroot_device_lite_cert": "lite_cert.pem",
    "pki_subroot_device_lite_key": "lite_key.pem",
    "pki_auth_token": "auth_token",
}


# ---------------------------------------------------------------------------
# Tiny helpers
# ---------------------------------------------------------------------------

def node_ready_props(value: str | None) -> dict:
    return {NODE_READY_PROPERTY: value}


def get_image_tag_from_env() -> str:
    tag = os.environ.get("PKI_AUTHORITY_TAG")
    if tag:
        return tag

    try:
        manifest_path = Path(__file__).parent / "manifest.yaml"
        if manifest_path.exists():
            with open(manifest_path, "r", encoding="utf-8") as file:
                manifest = yaml.safe_load(file)
            if isinstance(manifest, dict):
                version = manifest.get("version")
                if isinstance(version, str) and version.strip():
                    return version.strip()
    except Exception as error:
        print(f"[pki-authority] failed to read manifest version: {error}", file=sys.stderr)

    return DEFAULT_PKI_AUTHORITY_IMAGE_TAG


def get_image_ref_from_env() -> str:
    tag = get_image_tag_from_env()
    return f"{PKI_AUTHORITY_IMAGE_REGISTRY}/{PKI_AUTHORITY_IMAGE_REPO}:{tag}"


def pull_image(image_ref: str) -> None:
    subprocess.run(["podman", "pull", image_ref], check=True)


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def get_node_tunnel_ip(node_id: str, wg_props: List[Dict[str, Any]]) -> Optional[str]:
    """Extract WireGuard tunnel IP for *node_id* from wgNodeProperties."""
    for prop in wg_props:
        if not isinstance(prop, dict):
            continue
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            value = prop.get("value")
            return value if isinstance(value, str) and value else None
    return None


def get_secret_from_state(state_json: Dict[str, Any], secret_id: str) -> Optional[str]:
    """Return base64-encoded secret value from ``state_json["swarmSecrets"]``."""
    secrets = state_json.get("swarmSecrets", [])
    if not isinstance(secrets, list):
        return None
    for secret in secrets:
        if isinstance(secret, dict) and secret.get("id") == secret_id:
            value = secret.get("value")
            return value if isinstance(value, str) else None
    return None


def compute_secrets_hash(state_json: Dict[str, Any]) -> str:
    """Deterministic hash of secret values from state for crash-safe change detection."""
    secrets = state_json.get("swarmSecrets", [])
    if not isinstance(secrets, list):
        return ""
    pairs = sorted(
        (s.get("id", ""), s.get("value", ""))
        for s in secrets if isinstance(s, dict)
    )
    return hashlib.sha256(repr(pairs).encode()).hexdigest()


# ---------------------------------------------------------------------------
# Secrets synchronisation
# ---------------------------------------------------------------------------

def sync_secrets(state_json: Dict[str, Any]) -> bool:
    """Sync secrets from *state_json* to disk.

    Compares each secret value (base64-encoded in state) with the file
    currently on disk in ``STORAGE_PATH``.

    Returns ``True`` if at least one file was written (i.e. a container
    restart is needed).

    Raises ``ValueError`` if any required secret is missing from state.
    """
    missing: List[str] = []
    changed = False

    STORAGE_PATH.mkdir(parents=True, exist_ok=True)

    for secret_id, filename in SECRETS_MAP.items():
        raw_value = get_secret_from_state(state_json, secret_id)
        if raw_value is None:
            missing.append(secret_id)
            continue

        value_bytes = raw_value.encode("utf-8") if isinstance(raw_value, str) else raw_value
        file_path = STORAGE_PATH / filename

        if file_path.exists() and file_path.read_bytes() == value_bytes:
            continue

        file_path.write_bytes(value_bytes)
        log(LogLevel.INFO, f"Secret '{secret_id}' written to {file_path}")
        changed = True

    if missing:
        raise ValueError(f"Required secrets missing from state: {', '.join(missing)}")

    return changed


# ---------------------------------------------------------------------------
# App-config generation
# ---------------------------------------------------------------------------

def patch_yaml_config(
    network_type: NetworkType,
    network_id: str,
    swarm_key: str,
    tunnel_ip: str,
) -> bool:
    """Generate application YAML config from the template.

    Patches:
      - ``pki.mode.networkSettings.networkType``
      - ``pki.mode.networkSettings.networkID``
      - ``pki.allowedChallenges`` (adds *untrusted* when applicable)
      - ``secretsStorage.static.swarmKey``
      - ``api.endpoints`` (WireGuard tunnel IP with fixed ports)

    Returns ``True`` if the file was written (content changed or didn't exist).
    """
    if not TEMPLATE_YAML.exists():
        raise FileNotFoundError(f"Config template not found: {TEMPLATE_YAML}")

    with open(TEMPLATE_YAML, "r", encoding="utf-8") as fh:
        config = yaml.safe_load(fh)

    # --- pki section ---
    pki = config.setdefault("pki", {})

    # allowedChallenges — add "untrusted" when network is untrusted
    if network_type == NetworkType.UNTRUSTED:
        challenges = pki.setdefault("allowedChallenges", [])
        if "untrusted" not in challenges:
            challenges.append("untrusted")

    # mode.networkSettings
    mode = pki.setdefault("mode", {})
    ns = mode.setdefault("networkSettings", {})
    ns["networkType"] = network_type.value
    if network_id:
        ns["networkID"] = network_id

    # --- secretsStorage ---
    ss = config.setdefault("secretsStorage", {})
    ss.setdefault("static", {})["swarmKey"] = swarm_key

    # --- api endpoints (tunnel IP + fixed ports) ---
    api = config.setdefault("api", {})
    api["endpoints"] = [
        f"https://{tunnel_ip}:{PKI_API_HTTPS_PORT}",
        f"http://{tunnel_ip}:{PKI_API_HTTP_PORT}",
        f"http://127.0.0.1:{PKI_API_HTTP_PORT}",
    ]

    # --- write only if changed ---
    new_content = yaml.dump(config, default_flow_style=False)
    if APP_CONFIG_PATH.exists() and APP_CONFIG_PATH.read_text(encoding="utf-8") == new_content:
        log(LogLevel.DEBUG, f"App config unchanged, skipping write: {APP_CONFIG_PATH}")
        return False

    BASE_DIR.mkdir(parents=True, exist_ok=True)
    APP_CONFIG_PATH.write_text(new_content, encoding="utf-8")
    log(LogLevel.INFO, f"Application config written to {APP_CONFIG_PATH}")
    return True


# ---------------------------------------------------------------------------
# Service lifecycle  (systemd + podman run)
# ---------------------------------------------------------------------------

def write_env_file(image_ref: str) -> bool:
    """Write the environment file consumed by the systemd unit.

    Returns ``True`` if the file was written (content changed or didn't exist).
    """
    content = (
        f"PKI_CONTAINER_IMAGE={image_ref}\n"
        f"CONFIG_CHAIN={CONFIG_CHAIN}\n"
    )
    if SERVICE_ENV_FILE.exists() and SERVICE_ENV_FILE.read_text(encoding="utf-8") == content:
        log(LogLevel.DEBUG, f"Env file unchanged, skipping write: {SERVICE_ENV_FILE}")
        return False

    BASE_DIR.mkdir(parents=True, exist_ok=True)
    SERVICE_ENV_FILE.write_text(content, encoding="utf-8")
    log(LogLevel.INFO, f"Env file written to {SERVICE_ENV_FILE}")
    return True


def is_service_active() -> bool:
    """Return ``True`` if the systemd service is active."""
    result = subprocess.run(
        ["systemctl", "is-active", SERVICE_UNIT],
        capture_output=True, text=True, check=False,
    )
    return result.stdout.strip() == "active"


def restart_service() -> None:
    """Restart (or start) the PKI Authority systemd service."""
    # Check whether systemd knows about the unit using `systemctl list-unit-files | grep`.
    unit_known = False
    try:
        check = subprocess.run([
            "bash", "-c",
            f"systemctl list-unit-files | grep -F '{SERVICE_UNIT}'"
        ], check=False, capture_output=True, text=True)
        # grep returns 0 only if match found AND stdout is not empty
        unit_known = (check.returncode == 0 and check.stdout.strip())
    except Exception:
        pass

    if not unit_known:
        log(LogLevel.INFO, f"[debug] systemd unit {SERVICE_UNIT} not found, attempting to install from local dir")
        # Fall back to installing local unit file if available in the service dir.
        local_unit = Path(__file__).parent / SERVICE_UNIT
        if local_unit.exists():
            target = Path("/etc/systemd/system") / SERVICE_UNIT
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(local_unit.read_text(encoding="utf-8"), encoding="utf-8")
            log(LogLevel.INFO, f"Installed systemd unit from {local_unit} to {target}")
            # Attempt to enable the unit (best-effort)
            try:
                subprocess.run(["systemctl", "enable", SERVICE_UNIT], check=False)
            except Exception:
                pass
        else:
            error_msg = f"Systemd unit {SERVICE_UNIT} not known and no local unit available to install from {local_unit}"
            log(LogLevel.ERROR, error_msg)
            raise FileNotFoundError(error_msg)

    # Always daemon-reload before restart to ensure systemd has latest unit state
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "restart", SERVICE_UNIT], check=True)
    log(LogLevel.INFO, f"Service '{SERVICE_UNIT}' restarted")


def stop_service() -> None:
    """Stop the PKI Authority systemd service (best-effort)."""
    subprocess.run(
        ["systemctl", "stop", SERVICE_UNIT],
        capture_output=True, check=False,
    )
    log(LogLevel.INFO, f"Service '{SERVICE_UNIT}' stopped")


