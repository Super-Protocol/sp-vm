#!/usr/bin/env python3
"""
PKI Authority LXC container configuration.
Configures the container with network, device access, and runtime settings.
"""

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pki_helpers import (
    log, LogLevel, detect_cpu_type, detect_vm_mode, detect_network_type,
    patch_yaml_config, patch_lxc_config, get_pki_authority_param,
    setup_iptables, update_pccs_url, generate_swarm_key, load_swarm_key,
    PKI_SERVICE_NAME, VMMode
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
    network_type = detect_network_type()
    
    log(LogLevel.INFO, f"CPU type: {cpu_type}")
    log(LogLevel.INFO, f"VM mode: {vm_mode.value}")
    log(LogLevel.INFO, f"Network type: {network_type}")
    
    try:
        pki_domain = get_pki_authority_param("domain")
        network_key = get_pki_authority_param("networkKey")
        
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
            network_key_hash=hashlib.sha256(network_key.encode()).hexdigest(),
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
