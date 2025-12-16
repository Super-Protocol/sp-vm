#!/usr/bin/env python3

import sys
import time
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput
import base64

# Import helpers
sys.path.insert(0, str(Path(__file__).parent))
from helpers import (
    delete_iptables_rules,
    detect_cpu_type,
    detect_vm_mode,
    patch_yaml_config,
    set_subroot_env,
    patch_lxc_config,
    setup_iptables,
    update_pccs_url,
    LXCContainer,
    PKI_SERVICE_NAME,
    get_node_tunnel_ip,
    init_container,
    VMMode,
    save_property_into_fs,
    read_property_from_fs,
)

# Configuration
plugin = ProvisionPlugin()

# Authority service property prefix and names
AUTHORITY_SERVICE_PREFIX = "pki_authority_"
AUTHORITY_SERVICE_PROPERTIES = ["auth_token", "basic_certificate", "basic_privateKey", "lite_certificate", "lite_privateKey"]
PROP_INITIALIZED = f"{AUTHORITY_SERVICE_PREFIX}initialized"

# Plugin commands
@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize PKI Authority service."""
    try:
        print("[*] Running PKI initialization")
        init_container()
        print("[*] PKI initialization completed")
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as e:
        error_msg = f"Failed to initialize PKI: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=input_data.local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply PKI Authority configuration and start service."""

    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    if not isinstance(state_json, dict):
        return PluginOutput(status="error", error_message="Invalid state format", local_state=local_state)

    wg_props = state_json.get("wgNodeProperties", [])
    authority_props = state_json.get("authorityServiceProperties", [])
    
    # Convert authority service properties to dict for easier access
    authority_config = {prop["name"]: prop["value"] for prop in authority_props}

    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(status="error", error_message="Local node has no WireGuard tunnel IP", local_state=local_state)
    
    try:
        vm_mode = detect_vm_mode()
        initialized = authority_config.get(PROP_INITIALIZED)
        # If initialized is true, verify all required properties are present
        if initialized == "true":
            missing = []
            
            for prop in AUTHORITY_SERVICE_PROPERTIES:
                prop_name = f"{AUTHORITY_SERVICE_PREFIX}{prop}"
                prop_value = authority_config.get(prop_name, "")
                
                if not prop_value:
                    missing.append(prop_name)

            
            if missing:
                error_msg = f"Service marked as initialized but missing properties: {', '.join(missing)}"
                print(f"[!] {error_msg}", file=sys.stderr)
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
            
        if vm_mode == VMMode.SWARM_NORMAL and initialized != "true":
            return PluginOutput(
                status="postponed",
                error_message="Waiting for authority service properties to be initialized",
                local_state=local_state
            )

        cpu_type = detect_cpu_type()
        delete_iptables_rules()
        patch_yaml_config(cpu_type)
        set_subroot_env()
        patch_lxc_config(cpu_type)
        update_pccs_url()
        setup_iptables(local_tunnel_ip)
        container = LXCContainer(PKI_SERVICE_NAME)
        
        # Start or restart LXC container
        if container.is_running():
            print(f"[*] Restarting LXC container {PKI_SERVICE_NAME}")
            
            exit_code = container.stop(graceful_timeout=30, command_timeout=60)
            if exit_code != 0:
                raise Exception(f"Failed to stop container with exit code {exit_code}")
        
        if initialized == "true":
            for prop in AUTHORITY_SERVICE_PROPERTIES:
                prop_name = f"{AUTHORITY_SERVICE_PREFIX}{prop}"
                prop_value = authority_config.get(prop_name, "")
                save_property_into_fs(prop, base64.b64decode(prop_value))

        exit_code = container.start(timeout=30)
        if exit_code != 0:
            raise Exception(f"Failed to start container with exit code {exit_code}")

        print(f"[*] LXC container {PKI_SERVICE_NAME} is running")

        # If not initialized, wait for tee-pki service to generate property files
        if initialized != "true":
            missing_properties = AUTHORITY_SERVICE_PROPERTIES.copy()
            timeout = 30
            interval = 5
            elapsed = 0
            collected_properties = {}
            
            while elapsed < timeout:
                # Try to read each missing property
                for prop in missing_properties[:]:
                    success, value = read_property_from_fs(prop)              
                    
                    if success:
                        collected_properties[f"{AUTHORITY_SERVICE_PREFIX}{prop}"] = base64.b64encode(value).decode()
                        missing_properties.remove(prop)
                
                # Check if all properties collected
                if not missing_properties:
                    print("[*] All property files have been generated by tee-pki service")
                    
                    # Add initialized flag
                    collected_properties[PROP_INITIALIZED] = "true"
                    
                    return PluginOutput(
                        status="completed",
                        cluster_properties=collected_properties,
                        local_state=local_state
                    )
                
                # Show what's still missing
                print(f"[*] Waiting for property files. Missing: {', '.join(missing_properties)} (elapsed: {elapsed}s)")
                
                time.sleep(interval)
                elapsed += interval
            
            # Timeout reached
            return PluginOutput(
                status="postponed",
                error_message=f"Timeout waiting for tee-pki to generate property files: {', '.join(missing_properties)}",
                local_state=local_state
            )
        
        return PluginOutput(status="completed", local_state=local_state)
        
    except Exception as e:
        error_msg = f"Apply failed: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check health of PKI Authority service."""
    local_state = input_data.local_state or {}

    try:
        container = LXCContainer(PKI_SERVICE_NAME)
        
        if container.is_running() and container.is_service_healthy():
            return PluginOutput(status="completed", local_state=local_state)
        else:
            return PluginOutput(
                status="error",
                error_message="PKI service is not healthy or container is not running",
                local_state=local_state
            )
    except Exception as e:
        error_msg = f"Health check failed: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize PKI Authority service setup."""
    print("[*] PKI Authority finalized")
    return PluginOutput(status="completed", local_state=input_data.local_state)


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy PKI Authority service and clean up."""
    local_state = input_data.local_state or {}

    try:
        container = LXCContainer(PKI_SERVICE_NAME)
        
        # Stop container if running
        if container.is_running():
            exit_code = container.stop(graceful_timeout=30, command_timeout=60)
            if exit_code != 0:
                print(f"[!] Warning: Failed to stop container gracefully", file=sys.stderr)
        
        # Destroy container
        exit_code = container.destroy()
        if exit_code != 0:
            error_msg = f"Failed to destroy container with exit code {exit_code}"
            return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
        
        delete_iptables_rules()

        print("[*] PKI Authority destroyed")
        return PluginOutput(status="completed", local_state=local_state)

    except Exception as e:
        error_msg = f"Destroy failed: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


if __name__ == "__main__":
    plugin.run()
