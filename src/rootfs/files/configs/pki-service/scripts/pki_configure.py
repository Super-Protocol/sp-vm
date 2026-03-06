#!/usr/bin/env python3
"""
PKI Authority container configuration (Podman).
Generates pod YAML, application config, and QCNL config for podman play kube.
"""

import sys
import argparse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pki_helpers import (
    log, LogLevel, detect_cpu_type, detect_vm_mode, detect_network_type,
    patch_yaml_config, generate_pod_yaml, generate_qcnl_conf,
    get_pki_authority_param, setup_pccs_iptables,
    generate_swarm_key, load_swarm_key,
    read_network_type_from_certificate,
    VMMode, STORAGE_PATH
)


def main():
    """Main configuration logic."""
    parser = argparse.ArgumentParser(description="Configure PKI Authority podman runtime artifacts")
    parser.add_argument("--image", required=True, help="Container image for PKI Authority")
    args = parser.parse_args()

    log(LogLevel.INFO, "Starting PKI Authority configuration")
    log(LogLevel.INFO, f"Container image: {args.image}")

    # Ensure persistent storage exists
    STORAGE_PATH.mkdir(parents=True, exist_ok=True)

    # Detect environment
    cpu_type = detect_cpu_type()
    vm_mode = detect_vm_mode()

    log(LogLevel.INFO, f"CPU type: {cpu_type}")
    log(LogLevel.INFO, f"VM mode: {vm_mode.value}")

    # Network type detection based on VM mode
    if vm_mode == VMMode.SWARM_INIT:
        network_type = detect_network_type()
        log(LogLevel.INFO, f"Network type (from cmdline): {network_type.value}")
    else:
        required_files = [
            "basic_certificate",
            "basic_privateKey",
            "lite_certificate",
            "lite_privateKey"
        ]

        missing_files = [f for f in required_files if not (STORAGE_PATH / f).exists()]
        if missing_files:
            error_msg = (
                f"Required files missing in {STORAGE_PATH}: {', '.join(missing_files)}. "
                "These files should be synced by pki-authority-sync.service before this script runs."
            )
            log(LogLevel.ERROR, error_msg)
            sys.exit(1)

        log(LogLevel.INFO, "All required swarm-storage files are present")

        network_type = read_network_type_from_certificate()
        log(LogLevel.INFO, f"Network type (from certificate): {network_type.value}")

    try:
        try:
            pki_domain = get_pki_authority_param("domain")
        except (FileNotFoundError, ValueError) as e:
            log(LogLevel.WARN, f"Failed to read domain from config: {e}")
            pki_domain = "localhost"
            log(LogLevel.INFO, f"Using default domain: {pki_domain}")

        network_id = get_pki_authority_param("networkID")

        # Get or generate swarm key based on VM mode
        if vm_mode == VMMode.SWARM_INIT:
            try:
                swarm_key = load_swarm_key()
            except FileNotFoundError:
                swarm_key = generate_swarm_key()
        else:
            swarm_key = load_swarm_key()

        # Generate patched application config
        patch_yaml_config(
            cpu_type=cpu_type,
            vm_mode=vm_mode,
            network_type=network_type,
            pki_domain=pki_domain,
            network_id=network_id,
            swarm_key=swarm_key
        )
        log(LogLevel.INFO, "Application config generated successfully")

        # Setup iptables DNAT for PCCS access from container and generate QCNL config
        pccs_addr = setup_pccs_iptables()
        generate_qcnl_conf(pccs_addr, image=args.image)
        log(LogLevel.INFO, "QCNL config generated successfully")

        # Generate pod YAML for podman play kube
        generate_pod_yaml(cpu_type=cpu_type, vm_mode=vm_mode, image=args.image)
        log(LogLevel.INFO, "Pod YAML generated successfully")

    except Exception as e:
        log(LogLevel.ERROR, f"Configuration failed: {e}")
        sys.exit(1)

    log(LogLevel.INFO, "PKI Authority configuration completed successfully")
    sys.exit(0)


if __name__ == "__main__":
    main()
