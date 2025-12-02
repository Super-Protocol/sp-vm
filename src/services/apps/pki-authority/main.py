#!/usr/bin/env python3

import sys
import subprocess
import time
import urllib.request
import ssl
from typing import List, Optional

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
PKI_SERVICE_NAME = "pki-authority"

plugin = ProvisionPlugin()


# Helpers
def get_node_tunnel_ip(node_id: str, wg_props: List[dict]) -> Optional[str]:
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None

def lxc_start_container(container_name: str, timeout: int = 30) -> int:
    """Start LXC container. Returns exit code."""
    print(f"[*] Starting LXC container {container_name}")
    result = subprocess.run(
        ["lxc-start", "-n", container_name],
        capture_output=True,
        text=True,
        timeout=timeout
    )
    
    return result.returncode

def lxc_stop_container(container_name: str, graceful_timeout: int = 30, command_timeout: int = 60) -> int:
    """Stop LXC container gracefully. Returns exit code."""
    print(f"[*] Stopping LXC container {container_name} gracefully")
    result = subprocess.run(
        ["lxc-stop", "-n", container_name, "-t", str(graceful_timeout)],
        capture_output=True,
        text=True,
        timeout=command_timeout
    )

    return result.returncode

def is_pki_running() -> bool:
    """Check if PKI Authority service is running."""
    try:
        # 1. Check if LXC container is running
        result = subprocess.run(
            ["lxc-ls", "--running"],
            capture_output=True,
            text=True
        )
        if PKI_SERVICE_NAME not in result.stdout:
            print(f"[*] LXC container {PKI_SERVICE_NAME} is not running")
            return False
        
        # 2. Check tee-pki service status inside container
        result = subprocess.run(
            ["lxc-attach", "-n", PKI_SERVICE_NAME, "--", "systemctl", "is-active", "tee-pki"],
            capture_output=True,
            text=True
        )
        status = result.stdout.strip()
        
        if status not in ["active", "activating"]:
            print(f"[*] Service tee-pki status: {status}")
            return False
        
        # 3. If service is active, check how long it's been running
        if status == "active":
            result = subprocess.run(
                ["lxc-attach", "-n", PKI_SERVICE_NAME, "--", "systemctl", "show", "tee-pki", "--property=ActiveEnterTimestamp"],
                capture_output=True,
                text=True
            )
            
            # Parse ActiveEnterTimestamp
            for line in result.stdout.split('\n'):
                if line.startswith('ActiveEnterTimestamp='):
                    timestamp_str = line.split('=', 1)[1].strip()
                    if timestamp_str and timestamp_str != '0':
                        # Parse timestamp (format: "Day YYYY-MM-DD HH:MM:SS TZ")
                        try:
                            # Get timestamp in seconds since epoch
                            ts_result = subprocess.run(
                                ["date", "+%s", "-d", timestamp_str],
                                capture_output=True,
                                text=True
                            )
                            start_time = int(ts_result.stdout.strip())
                            current_time = int(time.time())
                            uptime_seconds = current_time - start_time
                            
                            # If running more than 2 minutes (120 seconds), check healthcheck
                            if uptime_seconds > 120:
                                # Get container IP
                                ip_result = subprocess.run(
                                    ["lxc-info", "-n", PKI_SERVICE_NAME, "-iH"],
                                    capture_output=True,
                                    text=True
                                )
                                container_ip = ip_result.stdout.strip() if ip_result.stdout.strip() else None
                                
                                if container_ip:
                                    # Perform HTTPS healthcheck without certificate verification
                                    try:
                                        ctx = ssl.create_default_context()
                                        ctx.check_hostname = False
                                        ctx.verify_mode = ssl.CERT_NONE
                                        
                                        req = urllib.request.Request(f"https://{container_ip}/healthcheck")
                                        with urllib.request.urlopen(req, context=ctx, timeout=5) as response:
                                            if response.status == 200:
                                                return True
                                            else:
                                                print(f"[*] Healthcheck returned status: {response.status}")
                                                return False
                                    except Exception as e:
                                        print(f"[*] Healthcheck failed: {e}")
                                        return False
                        except Exception as e:
                            print(f"[*] Failed to parse service uptime: {e}")
        
        # Service is active or activating (but not ready for healthcheck yet)
        return True
        
    except Exception as e:
        print(f"[!] Failed to check PKI status: {e}", file=sys.stderr)
        return False

# Plugin commands
@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize PKI Authority service."""
    try:
        # Run PKI initialization script
        print("[*] Running PKI initialization script")
        result = subprocess.run(
            ["/usr/local/bin/create-and-configure-pki.sh"],
            capture_output=True,
            text=True,
            timeout=180
        )
        
        if result.returncode != 0:
            error_msg = f"PKI initialization script failed with exit code {result.returncode}: {result.stderr}"
            print(f"[!] {error_msg}", file=sys.stderr)
            return PluginOutput(status="error", error_message=error_msg, local_state=input_data.local_state)
        
        print("[*] PKI initialization completed")
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except subprocess.CalledProcessError as e:
        error_msg = f"Failed to initialize PKI: {e.stderr if e.stderr else str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=input_data.local_state)
    except Exception as e:
        error_msg = f"Unexpected error: {str(e)}"
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
        # Start or restart LXC container
        if is_pki_running():
            print(f"[*] Restarting LXC container {PKI_SERVICE_NAME}")
            
            # Stop container gracefully
            exit_code = lxc_stop_container(PKI_SERVICE_NAME, graceful_timeout=30, command_timeout=60)
            if exit_code != 0:
                error_msg = f"Failed to stop container with exit code {exit_code}"
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
            
            # Start container
            exit_code = lxc_start_container(PKI_SERVICE_NAME, timeout=30)
            if exit_code != 0:
                error_msg = f"Failed to start container with exit code {exit_code}"
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
        else:
            # Start container
            exit_code = lxc_start_container(PKI_SERVICE_NAME, timeout=30)
            if exit_code != 0:
                error_msg = f"Failed to start container with exit code {exit_code}"
                return PluginOutput(status="error", error_message=error_msg, local_state=local_state)

        print(f"[*] LXC container {PKI_SERVICE_NAME} is running")
        return PluginOutput(status="completed", local_state=local_state)

    except subprocess.CalledProcessError as e:
        error_msg = f"Failed to start service: {e.stderr if e.stderr else str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
    except Exception as e:
        error_msg = f"Unexpected error: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check health of PKI Authority service."""
    local_state = input_data.local_state or {}

    if is_pki_running():
        return PluginOutput(status="healthy", local_state=local_state)
    else:
        return PluginOutput(
            status="unhealthy",
            error_message="Service is not running",
            local_state=local_state
        )


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
        print(f"[*] Stopping {PKI_SERVICE_NAME}")
        subprocess.run(
            ["systemctl", "stop", PKI_SERVICE_NAME],
            capture_output=True,
            text=True,
            timeout=30
        )

        print(f"[*] Disabling {PKI_SERVICE_NAME}")
        subprocess.run(
            ["systemctl", "disable", PKI_SERVICE_NAME],
            capture_output=True,
            text=True
        )

        print("[*] PKI Authority destroyed")
        return PluginOutput(status="completed", local_state=local_state)

    except Exception as e:
        error_msg = f"Destroy failed: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


if __name__ == "__main__":
    plugin.run()
