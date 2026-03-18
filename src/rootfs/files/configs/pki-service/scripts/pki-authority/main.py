#!/usr/bin/env python3
"""PKI Authority service provisioning plugin."""

import sys
import traceback
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
        log(LogLevel.INFO, "[debug] init started")
        log(LogLevel.INFO, f"[debug] init local_state_keys={sorted(list((input_data.local_state or {}).keys()))}")
        image_ref = get_image_ref_from_env()
        log(LogLevel.INFO, f"[debug] resolved image_ref={image_ref}")
        log(LogLevel.INFO, f"Pulling image {image_ref}")
        pull_image(image_ref)
        log(LogLevel.INFO, "Image pulled successfully")
        log(LogLevel.INFO, "[debug] init completed")
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as e:
        tb = traceback.format_exc()
        error_msg = f"Init failed: {e}"
        log(LogLevel.ERROR, error_msg)
        log(LogLevel.ERROR, f"[debug] init traceback:\n{tb}")
        return PluginOutput(status="error", error_message=f"{error_msg}\n{tb}", local_state=input_data.local_state)


# ── apply ────────────────────────────────────────────────────────────────────

@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Configure and (re)start the PKI Authority container."""
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}
    local_node_id = input_data.local_node_id
    wg_props = state_json.get("wgNodeProperties", [])

    try:
        log(LogLevel.INFO, "[debug] apply started")
        log(LogLevel.INFO, f"[debug] apply context: local_node_id={local_node_id}")
        log(LogLevel.INFO, f"[debug] state keys: {sorted(list(state_json.keys())) if isinstance(state_json, dict) else '<non-dict>'}")
        log(LogLevel.INFO, f"[debug] wgNodeProperties count={len(wg_props) if isinstance(wg_props, list) else 'n/a'}")
        swarm_secrets = state_json.get("swarmSecrets", []) if isinstance(state_json, dict) else []
        secret_ids = [s.get("id") for s in swarm_secrets if isinstance(s, dict) and s.get("id")]
        log(LogLevel.INFO, f"[debug] swarmSecrets count={len(swarm_secrets) if isinstance(swarm_secrets, list) else 'n/a'}, ids={sorted(secret_ids)}")
        log(LogLevel.INFO, f"[debug] local_state keys={sorted(list(local_state.keys()))}")

        # 1. WireGuard tunnel IP
        log(LogLevel.INFO, "[debug] step=1 resolve tunnel_ip")
        tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
        log(LogLevel.INFO, f"[debug] resolved tunnel_ip={tunnel_ip}")
        if not tunnel_ip:
            log(LogLevel.WARN, "[debug] apply postponed: tunnel_ip is missing")
            return PluginOutput(
                status="postponed",
                error_message="Waiting for WireGuard tunnel IP",
                local_state=local_state,
            )

        # 2. Sync secrets to disk (raises ValueError if any are missing)
        try:
            log(LogLevel.INFO, "[debug] step=2 sync secrets")
            log(LogLevel.INFO, "[debug] syncing secrets")
            config_changed = sync_secrets(state_json)
            log(LogLevel.INFO, f"[debug] sync_secrets changed={config_changed}")
        except ValueError as exc:
            log(LogLevel.WARN, f"[debug] apply postponed: secrets not ready ({exc})")
            return PluginOutput(
                status="postponed",
                error_message=str(exc),
                local_state=local_state,
            )

        # 3. Read environment parameters
        log(LogLevel.INFO, "[debug] step=3 read runtime params")
        log(LogLevel.INFO, "[debug] reading runtime parameters")
        network_type = read_network_type_from_certificate()
        swarm_key = load_swarm_key()
        network_id = get_pki_authority_param("networkID")
        log(LogLevel.INFO, f"[debug] network_type={network_type.value}, network_id={network_id}")
        log(LogLevel.INFO, f"[debug] swarm_key loaded: len={len(swarm_key)}")

        # 4. Generate app-config.yaml (writes only if changed)
        log(LogLevel.INFO, "[debug] step=4 patch app-config")
        log(LogLevel.INFO, "[debug] patching app-config.yaml")
        config_changed |= patch_yaml_config(
            network_type=network_type,
            network_id=network_id,
            swarm_key=swarm_key,
            tunnel_ip=tunnel_ip,
        )
        log(LogLevel.INFO, f"[debug] config_changed after yaml={config_changed}")

        # 5. Write env file (writes only if changed)
        log(LogLevel.INFO, "[debug] step=5 write env")
        image_ref = get_image_ref_from_env()
        log(LogLevel.INFO, f"[debug] writing env file for image_ref={image_ref}")
        config_changed |= write_env_file(image_ref)
        log(LogLevel.INFO, f"[debug] config_changed after env={config_changed}")

        log(LogLevel.INFO, "[debug] step=6 evaluate service state")
        service_active = is_service_active()
        log(LogLevel.INFO, f"[debug] service_active={service_active}")

        if not service_active:
            log(LogLevel.INFO, "[debug] service inactive, restarting to start it")
            restart_service()
            log(LogLevel.INFO, "Service started")
        elif config_changed:
            log(LogLevel.INFO, "[debug] service active, config changed -> restarting")
            restart_service()
            log(LogLevel.INFO, "Service restarted due to config changes")
        else:
            log(LogLevel.INFO, "[debug] service active, no config changes -> skip restart")
            log(LogLevel.INFO, "No changes detected, service already running")

        log(LogLevel.INFO, "[debug] apply completed")
        return PluginOutput(
            status="completed",
            local_state=local_state,
        )

    except Exception as e:
        tb = traceback.format_exc()
        error_msg = f"Apply failed: {e}"
        log(LogLevel.ERROR, error_msg)
        log(LogLevel.ERROR, f"[debug] apply traceback:\n{tb}")
        return PluginOutput(status="error", error_message=f"{error_msg}\n{tb}", local_state=local_state)


# ── health ───────────────────────────────────────────────────────────────────

@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check that the PKI Authority systemd service is active."""
    local_state = input_data.local_state or {}
    log(LogLevel.INFO, "[debug] health started")

    service_active = is_service_active()
    log(LogLevel.INFO, f"[debug] health service_active={service_active}")

    if not service_active:
        log(LogLevel.WARN, "[debug] health failed: service is not running")
        return PluginOutput(
            status="error",
            error_message="Service is not running",
            node_properties=node_ready_props("false"),
            local_state=local_state,
        )

    log(LogLevel.INFO, "[debug] health completed successfully")
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
        log(LogLevel.INFO, "[debug] destroy started")
        stop_service()
        log(LogLevel.INFO, "PKI Authority destroyed")
        log(LogLevel.INFO, "[debug] destroy completed")
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
