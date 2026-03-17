#!/usr/bin/env python3
"""PKI Authority service provisioning plugin."""

import sys
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

sys.path.insert(0, str(Path(__file__).parent))
from helpers import (
    log, LogLevel,
    get_image_ref_from_env, pull_image,
    get_node_tunnel_ip, node_ready_props,
    sync_secrets, patch_yaml_config,
    is_service_active, restart_service, stop_service, write_env_file,
    read_network_type_from_certificate, load_swarm_key, get_pki_authority_param,
)


plugin = ProvisionPlugin()


# ── init ─────────────────────────────────────────────────────────────────────

@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Pull the container image."""
    try:
        image_ref = get_image_ref_from_env()
        log(LogLevel.INFO, f"Pulling image {image_ref}")
        pull_image(image_ref)
        log(LogLevel.INFO, "Image pulled successfully")
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as e:
        error_msg = f"Init failed: {e}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(status="error", error_message=error_msg, local_state=input_data.local_state)


# ── apply ────────────────────────────────────────────────────────────────────

@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Configure and (re)start the PKI Authority container."""
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}
    local_node_id = input_data.local_node_id
    wg_props = state_json.get("wgNodeProperties", [])

    try:
        # 1. WireGuard tunnel IP
        tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
        if not tunnel_ip:
            return PluginOutput(
                status="postponed",
                error_message="Waiting for WireGuard tunnel IP",
                local_state=local_state,
            )

        # 2. Sync secrets to disk (raises ValueError if any are missing)
        try:
            config_changed = sync_secrets(state_json)
        except ValueError as exc:
            return PluginOutput(
                status="postponed",
                error_message=str(exc),
                local_state=local_state,
            )

        # 3. Read environment parameters
        network_type = read_network_type_from_certificate()
        swarm_key = load_swarm_key()
        network_id = get_pki_authority_param("networkID")

        # 4. Generate app-config.yaml (writes only if changed)
        config_changed |= patch_yaml_config(
            network_type=network_type,
            network_id=network_id,
            swarm_key=swarm_key,
            tunnel_ip=tunnel_ip,
        )

        # 5. Write env file (writes only if changed)
        image_ref = get_image_ref_from_env()
        config_changed |= write_env_file(image_ref)

        if not is_service_active():
            restart_service()
            log(LogLevel.INFO, "Service started")
        elif config_changed:
            restart_service()
            log(LogLevel.INFO, "Service restarted due to config changes")
        else:
            log(LogLevel.INFO, "No changes detected, service already running")

        return PluginOutput(
            status="completed",
            local_state=local_state,
        )

    except Exception as e:
        error_msg = f"Apply failed: {e}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


# ── health ───────────────────────────────────────────────────────────────────

@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check that the PKI Authority systemd service is active."""
    local_state = input_data.local_state or {}

    if not is_service_active():
        return PluginOutput(
            status="error",
            error_message="Service is not running",
            node_properties=node_ready_props("false"),
            local_state=local_state,
        )

    return PluginOutput(
        status="completed",
        node_properties=node_ready_props("true"),
        local_state=local_state,
    )


# ── finalize ─────────────────────────────────────────────────────────────────

@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    log(LogLevel.INFO, "Finalize — no-op")
    return PluginOutput(status="completed", local_state=input_data.local_state)


# ── destroy ──────────────────────────────────────────────────────────────────

@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Stop and remove the container."""
    local_state = input_data.local_state or {}
    try:
        stop_service()
        log(LogLevel.INFO, "PKI Authority destroyed")
        return PluginOutput(
            status="completed",
            node_properties=node_ready_props(None),
            local_state=local_state,
        )
    except Exception as e:
        error_msg = f"Destroy failed: {e}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


if __name__ == "__main__":
    plugin.run()
