#!/usr/bin/env python3

import argparse
import secrets
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import yaml

SWARM_KEY_FILE = "/etc/swarm/swarm.key"
SWARM_CPU_TYPE_FILE = "/etc/swarm/swarm-cpu-type"
SERVICE_NAME = "pki-cert-init"


def log(level: str, message: str):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{SERVICE_NAME}] [{level}] {message}", file=sys.stderr)


def detect_network_type() -> str:
    cpu_type_path = Path(SWARM_CPU_TYPE_FILE)

    def read_cpu_type() -> str | None:
        if cpu_type_path.exists():
            first_line = cpu_type_path.read_text(encoding="utf-8").splitlines()[0].strip()
            if first_line:
                return first_line
        return None

    cpu_type = read_cpu_type()
    if cpu_type is None:
        subprocess.run(
            ["/usr/bin/pki-cert-generator", "get-cpu-type", "--output", SWARM_CPU_TYPE_FILE],
            check=True
        )
        cpu_type = read_cpu_type()

    # TODO: implement two types of virtual machine
    return "untrusted" #if cpu_type == "untrusted" else "trusted"


def patch_template(template: dict, network_type: str) -> dict:
    certificates = template.get("certificates")
    if not isinstance(certificates, list):
        raise ValueError("Invalid template: 'certificates' must be a list")

    for cert in certificates:
        if isinstance(cert, dict) and cert.get("certRole") == "root":
            cert["networkType"] = network_type

    return template


def has_non_empty_value(value, field_name: str, value_type: type) -> bool:
    if value is None:
        return False

    if value_type not in (list, str):
        raise ValueError(f"Unsupported value type '{value_type.__name__}' for field '{field_name}'")

    if not isinstance(value, value_type):
        type_name = "list" if value_type is list else "string"
        raise ValueError(f"Invalid config: '{field_name}' must be a {type_name} or null")

    if value_type is str:
        return value.strip() != ""

    return len(value) > 0


def detect_swarm_pki_state(config_data: dict) -> str:
    swarm_db = config_data.get("swarm_db") or {}
    if not isinstance(swarm_db, dict):
        raise ValueError("Invalid config: 'swarm_db' must be a mapping")

    pki_authority = config_data.get("pki_authority")
    pki_authority = pki_authority or {}
    if not isinstance(pki_authority, dict):
        raise ValueError("Invalid config: 'pki_authority' must be a mapping")

    has_join_addresses = has_non_empty_value(
        swarm_db.get("join_addresses"),
        "swarm_db.join_addresses",
        list,
    )
    has_ca_bundle = has_non_empty_value(
        pki_authority.get("caBundle"),
        "pki_authority.caBundle",
        str,
    )
    has_servers = has_non_empty_value(
        pki_authority.get("servers"),
        "pki_authority.servers",
        list,
    )

    if not has_join_addresses and not has_ca_bundle and not has_servers:
        return "init"

    if has_join_addresses and has_ca_bundle and has_servers:
        return "normal"

    raise ValueError(
        "Inconsistent /sp/swarm/config.yaml: 'swarm_db.join_addresses', "
        "'pki_authority.caBundle' and 'pki_authority.servers' must be either all empty "
        "or all non-empty"
    )


def run_get_vm_mode(config_path: Path, output_path: Path) -> int:
    if not config_path.exists():
        log("ERROR", f"Config file does not exist: {config_path}")
        return 255

    try:
        config_data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if not isinstance(config_data, dict):
            raise ValueError("Invalid config: root must be a mapping")

        vm_mode = detect_swarm_pki_state(config_data)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(f"{vm_mode}\n", encoding="utf-8")
        log("INFO", f"Detected vm-mode '{vm_mode}' and saved to {output_path}")
        return 0
    except Exception as error:
        log("ERROR", f"Failed to detect vm-mode from /sp/swarm/config.yaml: {error}")
        return 255


def run_configure(template_path: Path, output_path: Path):
    if not template_path.exists():
        log("ERROR", f"Template file does not exist: {template_path}")
        return 1

    try:
        generate_swarm_key()
        log("INFO", f"Loading template from {template_path}")
        template_data = yaml.safe_load(template_path.read_text(encoding="utf-8"))
        if not isinstance(template_data, dict):
            raise ValueError("Invalid template: root must be a mapping")

        network_type = detect_network_type()
        log("INFO", f"Detected networkType={network_type}")

        rendered_data = patch_template(template_data, network_type)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            yaml.safe_dump(rendered_data, sort_keys=False),
            encoding="utf-8",
        )

        log("INFO", f"Rendered config saved to {output_path}")
        return 0
    except Exception as error:
        log("ERROR", f"Failed to render cert-gen config: {error}")
        return 1



def generate_swarm_key(swarm_key_path: Path = Path(SWARM_KEY_FILE)) -> None:
    """Generate a 32-byte swarm key once and reuse it on subsequent runs."""

    if swarm_key_path.exists():
        log("INFO", f"Swarm key file already exists at {swarm_key_path}, skipping generation")
        return

    log("INFO", "Generating new 32-byte swarm key")
    swarm_key = secrets.token_hex(32)

    try:
        if not swarm_key_path.parent.exists():
            swarm_key_path.parent.mkdir(parents=True, exist_ok=True)
            log("INFO", f"Created directory {swarm_key_path.parent}")

        with open(swarm_key_path, "w", encoding="utf-8") as file:
            file.write(swarm_key)

        swarm_key_path.chmod(0o600)

        log("INFO", f"Swarm key generated and saved to {swarm_key_path}")
    except Exception as error:
        error_msg = f"Failed to save swarm key: {error}"
        log("ERROR", error_msg)
        raise Exception(error_msg) from error

def main():
    parser = argparse.ArgumentParser(description="PKI cert-generator helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    configure_parser = subparsers.add_parser(
        "configure",
        help="Patch cert-gen template and render final config",
    )
    configure_parser.add_argument("--template", required=True, help="Path to cert-gen config template")
    configure_parser.add_argument("--output", required=True, help="Path to rendered cert-gen config")

    get_vm_mode_parser = subparsers.add_parser(
        "get-vm-mode",
        help="Detect vm-mode (init/normal) from /sp/swarm/config.yaml and save to file",
    )
    get_vm_mode_parser.add_argument(
        "--config",
        default="/sp/swarm/config.yaml",
        help="Path to swarm config (default: /sp/swarm/config.yaml)",
    )
    get_vm_mode_parser.add_argument(
        "--output",
        required=True,
        help="Path to output vm-mode file",
    )

    args = parser.parse_args()

    if args.command == "configure":
        return run_configure(Path(args.template), Path(args.output))

    if args.command == "get-vm-mode":
        return run_get_vm_mode(Path(args.config), Path(args.output))

    log("ERROR", f"Unsupported command: {args.command}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
