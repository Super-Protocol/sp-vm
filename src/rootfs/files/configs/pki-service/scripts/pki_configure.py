#!/usr/bin/env python3
"""
PKI Authority LXC container configuration.
Configures the container with network, device access, and runtime settings.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pki_helpers import (
    log, LogLevel, detect_cpu_type, detect_vm_mode, detect_network_type,
    patch_yaml_config, patch_lxc_config, get_pki_authority_param,
    setup_iptables, update_pccs_url, generate_swarm_key, load_swarm_key,
    read_network_type_from_certificate,
    PKI_SERVICE_NAME, VMMode, NetworkType, STORAGE_PATH
)


def main():
    """Main configuration logic."""
    log(LogLevel.INFO, "Starting PKI Authority configuration")
    
    # Check if container exists
    if not Path(f"/var/lib/lxc/{PKI_SERVICE_NAME}").exists():
        log(LogLevel.ERROR, f"Container '{PKI_SERVICE_NAME}' does not exist")
        sys.exit(1)
    
    # Detect environment
    cpu_type = detect_cpu_type()
    vm_mode = detect_vm_mode()
    
    log(LogLevel.INFO, f"CPU type: {cpu_type}")
    log(LogLevel.INFO, f"VM mode: {vm_mode.value}")
    
    # Network type detection based on VM mode
    if vm_mode == VMMode.SWARM_INIT:
        # In swarm-init mode: read from kernel cmdline
        network_type = detect_network_type()
        log(LogLevel.INFO, f"Network type (from cmdline): {network_type.value}")
    else:
        # In swarm-normal mode: verify required files exist in swarm-storage
        # These files should be synced by pki-authority-sync.service before this script runs
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
        
        # Read network type from certificate OID
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
            # In swarm-init mode: try to load existing key, generate if doesn't exist
            try:
                swarm_key = load_swarm_key()
            except FileNotFoundError:
                swarm_key = generate_swarm_key()
        else:
            # In swarm-normal mode: key must exist
            swarm_key = load_swarm_key()

        patch_yaml_config(
            cpu_type=cpu_type,
            vm_mode=vm_mode,
            network_type=network_type,
            pki_domain=pki_domain,
            network_id=network_id,
            swarm_key=swarm_key
        )
        log(LogLevel.INFO, "YAML config patched successfully")
        
        patch_lxc_config(cpu_type)
        log(LogLevel.INFO, "LXC config patched successfully")
        
        # Setup iptables rules
        setup_iptables()
        log(LogLevel.INFO, "iptables rules configured successfully")
        
        # Update PCCS URL in container
        update_pccs_url()
        log(LogLevel.INFO, "PCCS URL updated successfully")
        
    except Exception as e:
        log(LogLevel.ERROR, f"Configuration failed: {e}")
        sys.exit(1)
    
    log(LogLevel.INFO, "PKI Authority configuration completed successfully")
    sys.exit(0)


if __name__ == "__main__":
    main()
