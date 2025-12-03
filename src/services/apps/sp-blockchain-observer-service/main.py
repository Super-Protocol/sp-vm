#!/usr/bin/env python3

import subprocess
from typing import Optional
from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

SERVICE_UNIT = "sp-svc-blockchain-observer-service.service"
PROPERTY_PREFIX = "blockchain_observer_service"

plugin = ProvisionPlugin()

def is_service_active(service: str) -> tuple[bool, Optional[str]]:
    try:
        result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
        active = result.stdout.strip() == "active"
        return active, None if active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"

@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    return PluginOutput(status="completed", local_state=input_data.local_state)

@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    try:
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True, text=True)
        subprocess.run(["systemctl", "enable", SERVICE_UNIT], capture_output=True, text=True)
        r = subprocess.run(["systemctl", "restart", SERVICE_UNIT], capture_output=True, text=True)
        if r.returncode != 0:
            return PluginOutput(status="error", error_message=r.stderr, local_state=input_data.local_state)
        return PluginOutput(status="completed", node_properties={f"{PROPERTY_PREFIX}_node_ready": "true"}, local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status="error", error_message=str(e), local_state=input_data.local_state)

@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    active, err = is_service_active(SERVICE_UNIT)
    if not active:
        return PluginOutput(status="postponed", error_message=err or "service not running", local_state=input_data.local_state)
    return PluginOutput(status="completed", local_state=input_data.local_state)

@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    return PluginOutput(status="completed", local_state=input_data.local_state or {})

@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    try:
        subprocess.run(["systemctl", "stop", SERVICE_UNIT], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", SERVICE_UNIT], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        node_properties = {f"{PROPERTY_PREFIX}_node_ready": None}
        return PluginOutput(status="completed", node_properties=node_properties, local_state={})
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to destroy {SERVICE_UNIT}: {e}", local_state={})

if __name__ == "__main__":
    plugin.run()


