#!/usr/bin/env python3

import sys
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Import helpers
sys.path.insert(0, str(Path(__file__).parent))
from helpers import (
    BRIDGE_NAME,
    MONGODB_PORT,
    delete_iptables_rules,
    detect_cpu_type,
    detect_vm_mode,
    get_bridge_ip,
    patch_yaml_config,
    set_subroot_env,
    patch_lxc_config,
    setup_iptables,
    update_pccs_url,
    update_mongodb_connection,
    LXCContainer,
    PKI_SERVICE_NAME,
    get_node_tunnel_ip,
    init_container,
)

# Configuration
plugin = ProvisionPlugin()

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

    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(status="error", error_message="Local node has no WireGuard tunnel IP", local_state=local_state)

    try:
        cpu_type = detect_cpu_type()
        delete_iptables_rules()
        patch_yaml_config(cpu_type)
        set_subroot_env()
        patch_lxc_config(cpu_type)
        update_pccs_url()
        host_ip = get_bridge_ip(BRIDGE_NAME)
        mongodb_nodes = [f"{host_ip}:{MONGODB_PORT}"]
        update_mongodb_connection(mongodb_nodes)
        setup_iptables(local_tunnel_ip)
        container = LXCContainer(PKI_SERVICE_NAME)
        
        # Start or restart LXC container
        if container.is_running():
            print(f"[*] Restarting LXC container {PKI_SERVICE_NAME}")
            
            # Stop container gracefully
            exit_code = container.stop(graceful_timeout=30, command_timeout=60)
            if exit_code != 0:
                error_msg = f"Failed to stop container with exit code {exit_code}"
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
            
            # Start container
            exit_code = container.start(timeout=30)
            if exit_code != 0:
                error_msg = f"Failed to start container with exit code {exit_code}"
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
        else:
            # Start container
            exit_code = container.start(timeout=30)
            if exit_code != 0:
                error_msg = f"Failed to start container with exit code {exit_code}"
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)

        print(f"[*] LXC container {PKI_SERVICE_NAME} is running")
        return PluginOutput(status="completed", local_state=local_state)

    except Exception as e:
        error_msg = f"Failed to start service: {str(e)}"
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
