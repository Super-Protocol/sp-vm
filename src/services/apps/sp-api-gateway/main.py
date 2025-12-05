#!/usr/bin/env python3

import os
import subprocess
from pathlib import Path
from typing import Optional, List, Dict, Any
from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

SERVICE_UNIT = "sp-svc-api-gateway.service"
PROPERTY_PREFIX = "api_gateway"
DEFAULT_PORT = 3000
DEFAULT_LOG_LEVEL = "info"
DEFAULT_METRICS = {
    "metrics": {
        "defaultMetrics": {"enabled": True},
        "mode": "pull",
        "pull": {"enabled": False, "port": 9000, "path": "/metrics"},
        "push": {"enabled": False}
    }
}
NATS_PORT = 4222

plugin = ProvisionPlugin()

def is_service_active(service: str) -> tuple[bool, Optional[str]]:
    try:
        result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
        active = result.stdout.strip() == "active"
        return active, None if active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"

# Reuse WG node tunnel ip extraction

def get_node_tunnel_ip(node_id: str, props: List[Dict[str, Any]]) -> Optional[str]:
    for p in props:
        if p.get("node_id") == node_id and p.get("name") == "tunnel_ip":
            return p.get("value")
    return None

def pick_nats_host(state_json: Dict[str, Any]) -> str:
    """
    Pick one NATS host to connect to based on discovered NATS nodes' WG IPs.
    Falls back to localhost if none available.
    """
    nats_wg_props = state_json.get("natsWgNodeProperties") or []
    for p in nats_wg_props:
        v = p.get("value")
        if v:
            return v
    return "127.0.0.1"

def ensure_config_written(config_path: Path, nats_host: str) -> None:
    """
    Write configuration file for api-gateway using the provided nats host.
    """
    config_path.parent.mkdir(parents=True, exist_ok=True)
    lines: List[str] = []
    lines.append(f"natsUrl: nats://{nats_host}:{NATS_PORT}")
    lines.append(f"port: {DEFAULT_PORT}")
    lines.append(f"logLevel: {DEFAULT_LOG_LEVEL}")
    lines.append("metrics:")
    lines.append("  defaultMetrics:")
    lines.append("    enabled: true")
    lines.append("  mode: pull")
    lines.append("  push:")
    lines.append("    enabled: false")
    lines.append("  pull:")
    lines.append("    enabled: false")
    lines.append("    port: 9000")
    lines.append("    path: /metrics")
    content = "\n".join(lines) + "\n"
    config_path.write_text(content, encoding="UTF-8")

@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    # No package installation; service code is shipped into the VM image.
    return PluginOutput(status="completed", local_state=input_data.local_state)

@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}
    try:
        # Derive NATS host from state
        resolved_state: Dict[str, Any] = state_json if isinstance(state_json, dict) else {}
        nats_host = pick_nats_host(resolved_state)
        # Generate config under /etc for the runner
        config_path = Path("/etc/sp-swarm-services/apps/api-gateway/configuration.yaml")
        ensure_config_written(config_path, nats_host)
        # Enable and (re)start the service
        subprocess.run(["/bin/sh", "-lc", "systemctl daemon-reload"], check=False)
        subprocess.run(["/bin/sh", "-lc", f"systemctl enable {SERVICE_UNIT}"], check=False)
        r = subprocess.run(["/bin/sh", "-lc", f"systemctl restart {SERVICE_UNIT}"], capture_output=True, text=True)
        if r.returncode != 0:
            return PluginOutput(status="error", error_message=r.stderr or "failed to restart service", local_state=local_state)
        return PluginOutput(status="completed", node_properties={f"{PROPERTY_PREFIX}_node_ready": "true"}, local_state=local_state)
    except Exception as e:
        return PluginOutput(status="error", error_message=str(e), local_state=local_state)

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
        subprocess.run(["/bin/sh", "-lc", f"systemctl stop {SERVICE_UNIT}"], check=False)
        subprocess.run(["/bin/sh", "-lc", f"systemctl disable {SERVICE_UNIT}"], check=False)
        node_properties = {f"{PROPERTY_PREFIX}_node_ready": None}
        return PluginOutput(status="completed", node_properties=node_properties, local_state={})
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to destroy {SERVICE_UNIT}: {e}", local_state={})

if __name__ == "__main__":
    plugin.run()

