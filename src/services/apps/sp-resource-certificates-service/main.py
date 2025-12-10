#!/usr/bin/env python3

import subprocess
from pathlib import Path
from typing import Optional, List, Dict, Any
from jinja2 import Environment, FileSystemLoader
from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

SERVICE_UNIT = "sp-svc-resource-certificates-service.service"
PROPERTY_PREFIX = "resource_certificates_service"
DEFAULT_PORT = 3006
DEFAULT_LOG_LEVEL = "info"
NATS_PORT = 4222
MONGODB_PORT = 27017
ENV_CMDLINE = "argo_sp_env"

plugin = ProvisionPlugin()

def is_service_active(service: str) -> tuple[bool, Optional[str]]:
    try:
        result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
        active = result.stdout.strip() == "active"
        return active, None if active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"

def get_node_tunnel_ip(node_id: str, props: List[Dict[str, Any]]) -> Optional[str]:
    for p in props:
        if p.get("node_id") == node_id and p.get("name") == "tunnel_ip":
            return p.get("value")
    return None

def pick_nats_url(state_json: Dict[str, Any]) -> str:
    """
    Build NATS connection URL with all available NATS nodes' WG IPs.
    Format: nats://host1:port,nats://host2:port,...
    Falls back to localhost if none available.
    """
    nats_wg_props = state_json.get("natsWgNodeProperties") or []
    hosts = []
    for p in nats_wg_props:
        v = p.get("value")
        if v:
            hosts.append(f"nats://{v}:{NATS_PORT}")
    if hosts:
        return ",".join(hosts)
    return f"nats://127.0.0.1:{NATS_PORT}"

def pick_mongodb_url(state_json: Dict[str, Any]) -> str:
    """
    Build MongoDB connection URL with all available MongoDB nodes' WG IPs.
    Format: mongodb://host1:port,host2:port,...
    Falls back to localhost if none available.
    """
    mongodb_wg_props = state_json.get("mongodbWgNodeProperties") or []
    hosts = []
    for p in mongodb_wg_props:
        v = p.get("value")
        if v:
            hosts.append(f"{v}:{MONGODB_PORT}")
    if hosts:
        return f"mongodb://{','.join(hosts)}"
    return f"mongodb://127.0.0.1:{MONGODB_PORT}"

def get_cmdline_param(param_name: str) -> Optional[str]:
    """
    Read kernel command line from /proc/cmdline and extract a parameter value.
    Returns None if parameter is not found.
    """
    try:
        with open("/proc/cmdline", "r") as f:
            cmdline = f.read().strip()
        # Parse cmdline: split by spaces and find param=value
        for item in cmdline.split():
            if "=" in item:
                key, value = item.split("=", 1)
                if key == param_name:
                    return value
    except Exception:
        pass
    return None

def get_sp_env() -> str:
    """
    Get argo_sp_env from /proc/cmdline.
    Returns 'main' as default if not found or invalid.
    """
    env = get_cmdline_param(ENV_CMDLINE)
    if env in ["main", "develop", "testnet", "staging"]:
        return env
    return "main"  # default to main

def get_template_filename_for_env(env: str) -> str:
    """
    Map argo_sp_env value to template filename.
    main -> production.configuration.yaml.j2
    develop -> develop.configuration.yaml.j2
    testnet -> testnet.configuration.yaml.j2
    staging -> staging.configuration.yaml.j2
    """
    mapping = {
        "main": "production.configuration.yaml.j2",
        "develop": "develop.configuration.yaml.j2",
        "testnet": "testnet.configuration.yaml.j2",
        "staging": "staging.configuration.yaml.j2",
    }
    return mapping.get(env, "production.configuration.yaml.j2")

def create_template_context(
    nats_url: str,
    mongodb_url: str,
    port: int = DEFAULT_PORT,
    log_level: str = DEFAULT_LOG_LEVEL,
    jetstream_timeout: int = 10000,
    jetstream_reconnect: bool = True,
    jetstream_max_reconnect_attempts: int = -1,
    jetstream_reconnect_time_wait: int = 2000,
    metrics_default_enabled: bool = True,
    metrics_mode: str = "pull",
    metrics_push_enabled: bool = False,
    metrics_pull_enabled: bool = False,
    metrics_pull_port: int = 9007,
    metrics_pull_path: str = "/metrics",
) -> Dict[str, Any]:
    """
    Create template context dictionary for Jinja2 rendering.
    """
    return {
        "nats_url": nats_url,
        "mongodb_url": mongodb_url,
        "port": port,
        "log_level": log_level,
        "jetstream_timeout": jetstream_timeout,
        "jetstream_reconnect": jetstream_reconnect,
        "jetstream_max_reconnect_attempts": jetstream_max_reconnect_attempts,
        "jetstream_reconnect_time_wait": jetstream_reconnect_time_wait,
        "metrics_default_enabled": metrics_default_enabled,
        "metrics_mode": metrics_mode,
        "metrics_push_enabled": metrics_push_enabled,
        "metrics_pull_enabled": metrics_pull_enabled,
        "metrics_pull_port": metrics_pull_port,
        "metrics_pull_path": metrics_pull_path,
    }

def ensure_config_written(
    config_path: Path,
    nats_url: str,
    mongodb_url: str,
) -> None:
    """
    Write configuration file for resource-certificates-service using Jinja template.
    The template is selected based on argo_sp_env from /proc/cmdline.
    """
    # Get environment from kernel cmdline
    sp_env = get_sp_env()
    template_filename = get_template_filename_for_env(sp_env)

    template_dir = Path("/etc/sp-swarm-services/templates/resource-certificates-service")
    template_path = template_dir / template_filename

    if not template_path.exists():
        raise FileNotFoundError(f"Template file not found: {template_path}")

    # Create template context
    context = create_template_context(
        nats_url=nats_url,
        mongodb_url=mongodb_url,
        port=DEFAULT_PORT,
        log_level=DEFAULT_LOG_LEVEL,
        jetstream_timeout=10000,
        jetstream_reconnect=True,
        jetstream_max_reconnect_attempts=-1,
        jetstream_reconnect_time_wait=2000,
        metrics_default_enabled=True,
        metrics_mode="pull",
        metrics_push_enabled=False,
        metrics_pull_enabled=False,
        metrics_pull_port=9007,
        metrics_pull_path="/metrics",
    )

    # Render template
    env = Environment(loader=FileSystemLoader(str(template_dir)))
    template = env.get_template(template_filename)
    rendered_content = template.render(**context)

    # Write configuration file
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(rendered_content, encoding="UTF-8")

    # Verify file was created
    if not config_path.exists():
        raise RuntimeError(f"Failed to create configuration file at {config_path}")

@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    # No package installation; service code is shipped into the VM image.
    return PluginOutput(status="completed", local_state=input_data.local_state)

@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}
    try:
        # Derive service URLs from state (supporting multiple nodes)
        resolved_state: Dict[str, Any] = state_json if isinstance(state_json, dict) else {}
        nats_url = pick_nats_url(resolved_state)
        mongodb_url = pick_mongodb_url(resolved_state)

        # Generate config file based on argo_sp_env from /proc/cmdline
        config_path = Path("/etc/sp-swarm-services/apps/resource-certificates-service/configuration.yaml")
        ensure_config_written(
            config_path,
            nats_url,
            mongodb_url,
        )

        # Enable and (re)start the service
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True, text=True)
        subprocess.run(["systemctl", "enable", SERVICE_UNIT], capture_output=True, text=True)
        r = subprocess.run(["systemctl", "restart", SERVICE_UNIT], capture_output=True, text=True)
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
        subprocess.run(["systemctl", "stop", SERVICE_UNIT], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", SERVICE_UNIT], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        node_properties = {f"{PROPERTY_PREFIX}_node_ready": None}
        return PluginOutput(status="completed", node_properties=node_properties, local_state={})
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to destroy {SERVICE_UNIT}: {e}", local_state={})

if __name__ == "__main__":
    plugin.run()
