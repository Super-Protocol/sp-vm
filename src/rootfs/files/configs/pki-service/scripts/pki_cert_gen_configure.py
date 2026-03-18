#!/usr/bin/env python3

import argparse
import secrets
import sys
from datetime import datetime
from pathlib import Path

import yaml

SWARM_KEY_FILE = "/etc/swarm/swarm.key"
SERVICE_NAME = "pki-cert-init"


def log(level: str, message: str):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{SERVICE_NAME}] [{level}] {message}", file=sys.stderr)


def detect_network_type() -> str:
    cmdline_path = Path("/proc/cmdline")

    try:
        cmdline = cmdline_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "trusted"

    return "untrusted" if "allow_untrusted=true" in cmdline else "trusted"


def patch_template(template: dict, network_type: str) -> dict:
    certificates = template.get("certificates")
    if not isinstance(certificates, list):
        raise ValueError("Invalid template: 'certificates' must be a list")

    for cert in certificates:
        if isinstance(cert, dict) and cert.get("certRole") == "root":
            cert["networkType"] = network_type

    return template


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

    args = parser.parse_args()

    if args.command == "configure":
        return run_configure(Path(args.template), Path(args.output))

    log("ERROR", f"Unsupported command: {args.command}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
