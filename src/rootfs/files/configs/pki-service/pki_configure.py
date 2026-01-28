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
    PKI_SERVICE_NAME
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
    
    # Get parameters from swarm-env.yaml
    try:
        pki_domain = get_pki_authority_param("domain")
        network_key_hash = get_pki_authority_param("network_key_hash")
    except Exception as e:
        log(LogLevel.ERROR, f"Failed to read parameters: {e}")
        sys.exit(1)
    
    # Patch YAML config
    try:
        patch_yaml_config(
            cpu_type=cpu_type,
            vm_mode=vm_mode,
            network_type=network_type,
            pki_domain=pki_domain,
            network_key_hash=network_key_hash
        )
        log(LogLevel.INFO, "YAML config patched successfully")
    except Exception as e:
        log(LogLevel.ERROR, f"Failed to patch YAML config: {e}")
        sys.exit(1)
    
    # Patch LXC config
    try:
        patch_lxc_config(cpu_type)
        log(LogLevel.INFO, "LXC config patched successfully")
    except Exception as e:
        log(LogLevel.ERROR, f"Failed to patch LXC config: {e}")
        sys.exit(1)
    
    log(LogLevel.INFO, "PKI Authority configuration completed successfully")
    sys.exit(0)


if __name__ == "__main__":
    main()
