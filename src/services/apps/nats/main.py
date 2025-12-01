#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import socket
import time
from pathlib import Path
from typing import Optional

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
NATS_VERSION = os.environ.get("NATS_VERSION", "2")  # informational
NATS_CLIENT_PORT = 4222
NATS_CLUSTER_PORT = 6222
NATS_MONITOR_PORT = 8222
NATS_CONFIG_DIR = Path("/etc/nats")
NATS_CONFIG_FILE = NATS_CONFIG_DIR / "nats-server.conf"
NATS_DATA_DIR = Path("/var/lib/nats")
NATS_SERVICE_NAME = "nats-server"
NATS_BIN = "nats-server"
CLUSTER_NAME = os.environ.get("NATS_CLUSTER_NAME", "swarm-nats")

# Plugin setup
plugin = ProvisionPlugin()


# Helpers
def get_node_tunnel_ip(node_id: str, wg_props: list) -> Optional[str]:
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def check_all_nodes_have_wg(cluster_nodes: list, wg_props: list) -> bool:
    for node in cluster_nodes:
        node_id = node.get("node_id")
        if not get_node_tunnel_ip(node_id, wg_props):
            return False
    return True


def get_leader_node(state_json: dict) -> Optional[str]:
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def is_nats_available() -> bool:
    return shutil.which(NATS_BIN) is not None


def install_nats():
    try:
        if not os.path.exists("/etc/os-release"):
            raise Exception("Cannot detect OS: /etc/os-release not found")
        with open("/etc/os-release", "r") as f:
            os_release = f.read()
        if "ubuntu" in os_release.lower():
            r = subprocess.run(["apt-get", "update"], capture_output=True, text=True)
            if r.returncode != 0:
                raise Exception(f"apt-get update failed: {r.stderr}")
            # Use distro package if available
            r = subprocess.run(["apt-get", "install", "-y", "nats-server"], capture_output=True, text=True)
            if r.returncode != 0:
                raise Exception(f"nats-server installation failed: {r.stderr}")
            return
        raise Exception("Unsupported OS for NATS installation")
    except Exception as e:
        print(f"[!] Failed to install NATS: {e}", file=sys.stderr)
        raise


def write_nats_config(local_node_id: str, local_tunnel_ip: str, cluster_nodes: list, wg_props: list):
    NATS_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    NATS_DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Build routes for all peers except self
    routes = []
    for node in cluster_nodes:
        nid = node.get("node_id")
        t_ip = get_node_tunnel_ip(nid, wg_props)
        if not t_ip:
            continue
        if nid == local_node_id:
            continue
        routes.append(f"nats://{t_ip}:{NATS_CLUSTER_PORT}")

    cfg_lines = [
        f"port: {NATS_CLIENT_PORT}",
        f"http: {NATS_MONITOR_PORT}",
        f"host: {local_tunnel_ip}",
        "",
        "jetstream: true",
        f"server_name: {local_node_id}",
        "",
        "cluster: {",
        f"  name: {CLUSTER_NAME},",
        f"  host: {local_tunnel_ip},",
        f"  port: {NATS_CLUSTER_PORT},",
        "  routes: [",
    ]
    for r in routes:
        cfg_lines.append(f'    "{r}",')
    cfg_lines += [
        "  ]",
        "}",
        "",
        "resolver: memory",
        "no_auth_user: ''",
    ]

    NATS_CONFIG_FILE.write_text("\n".join(cfg_lines) + "\n")


def wait_for_tcp(ip: str, port: int, timeout_sec: int = 60) -> bool:
    start = time.time()
    last_err = None
    while time.time() - start < timeout_sec:
        try:
            with socket.create_connection((ip, port), timeout=3):
                return True
        except Exception as e:
            last_err = str(e)
            time.sleep(2)
    print(f"[!] Port {ip}:{port} not reachable within {timeout_sec}s. Last error: {last_err}", file=sys.stderr)
    return False


def is_service_active(service: str) -> tuple[bool, Optional[str]]:
    try:
        result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
        active = result.stdout.strip() == "active"
        return active, None if active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def is_cluster_initialized(nats_props: list) -> bool:
    for prop in nats_props:
        if prop.get("name") == "nats_cluster_initialized" and prop.get("value") == "true":
            return True
    return False


def mark_node_ready() -> dict:
    return {"nats_node_ready": "true"}


# Commands
@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    try:
        if not is_nats_available():
            install_nats()
        Path("/var/log/nats").mkdir(parents=True, exist_ok=True)
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status="error", error_message=str(e), local_state=input_data.local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    if not isinstance(state_json, dict):
        return PluginOutput(status="error", error_message="Invalid state format", local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    wg_props = state_json.get("wgNodeProperties", [])
    nats_props = state_json.get("natsNodeProperties", [])

    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        return PluginOutput(
            status="postponed",
            error_message="Waiting for WireGuard to be configured on all nodes",
            local_state=local_state,
        )

    leader_node_id = get_leader_node(state_json)
    is_leader = (leader_node_id == local_node_id)
    cluster_initialized = is_cluster_initialized(nats_props)

    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(status="error", error_message="Local node has no WireGuard tunnel IP", local_state=local_state)

    # Write NATS config based on current cluster view
    try:
        write_nats_config(local_node_id, local_tunnel_ip, cluster_nodes, wg_props)
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to write NATS config: {e}", local_state=local_state)

    # Enable and (re)start service if needed
    active, _ = is_service_active(NATS_SERVICE_NAME)
    needs_restart = not active

    try:
        subprocess.run(["systemctl", "enable", NATS_SERVICE_NAME], capture_output=True, text=True)
        result = subprocess.run(["systemctl", "restart", NATS_SERVICE_NAME], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status="error", error_message=f"Failed to start NATS: {result.stderr}", local_state=local_state)
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to start NATS: {e}", local_state=local_state)

    # Wait for client port to be ready
    if not wait_for_tcp(local_tunnel_ip, NATS_CLIENT_PORT, timeout_sec=60):
        return PluginOutput(
            status="postponed",
            error_message="NATS did not become ready within timeout",
            node_properties=mark_node_ready(),
            local_state=local_state,
        )

    # Leader marks cluster initialized (NATS clustering forms via routes automatically)
    if is_leader and not cluster_initialized:
        node_properties = {"nats_cluster_initialized": "true", "nats_node_ready": "true"}
        return PluginOutput(status="completed", node_properties=node_properties, local_state=local_state)

    if cluster_initialized:
        # Already initialized — ensure this node is marked ready
        return PluginOutput(status="completed", node_properties=mark_node_ready(), local_state=local_state)

    # Non-leader: mark ready and wait for leader
    return PluginOutput(
        status="postponed",
        error_message=f"Waiting for leader node {leader_node_id} to mark cluster initialized",
        node_properties=mark_node_ready(),
        local_state=local_state,
    )


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    active, err = is_service_active(NATS_SERVICE_NAME)
    if not active:
        if err and "Failed to" in err:
            return PluginOutput(status="error", error_message=err, local_state=local_state)
        return PluginOutput(status="postponed", error_message=err or "NATS service is not running", local_state=local_state)

    wg_props = state_json.get("wgNodeProperties", []) if isinstance(state_json, dict) else []
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(status="postponed", error_message="No tunnel IP available", local_state=local_state)

    # Check TCP connectivity to client port
    if not wait_for_tcp(local_tunnel_ip, NATS_CLIENT_PORT, timeout_sec=5):
        return PluginOutput(status="postponed", error_message="NATS not accepting connections yet", local_state=local_state)

    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    # No-op for now; could implement graceful cluster changes if needed
    return PluginOutput(status="completed", local_state=input_data.local_state or {})


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    try:
        subprocess.run(["systemctl", "stop", NATS_SERVICE_NAME], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", NATS_SERVICE_NAME], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if NATS_CONFIG_DIR.exists():
            shutil.rmtree(NATS_CONFIG_DIR, ignore_errors=True)
        if NATS_DATA_DIR.exists():
            shutil.rmtree(NATS_DATA_DIR, ignore_errors=True)
        node_properties = {
            "nats_node_ready": None,
            "nats_cluster_initialized": None,
        }
        return PluginOutput(status="completed", node_properties=node_properties, local_state={})
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to destroy NATS: {e}", local_state={})


if __name__ == "__main__":
    plugin.run()
