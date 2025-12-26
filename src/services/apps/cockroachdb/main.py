#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import hashlib
import time
import json
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
COCKROACH_VERSION = os.environ.get("COCKROACH_VERSION", "v23.2.0")
COCKROACH_SQL_PORT = 26257
COCKROACH_HTTP_PORT = 8180
COCKROACH_CONFIG_DIR = Path("/etc/cockroachdb")
COCKROACH_DATA_DIR = Path("/var/lib/cockroachdb")
COCKROACH_CERTS_DIR = COCKROACH_CONFIG_DIR / "certs"
COCKROACH_BIN = "/usr/local/bin/cockroach"

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def hash_node_id(node_id: str) -> str:
    """Create hex MD5 hash of node ID for CockroachDB node name compatibility."""
    return hashlib.md5(node_id.encode()).hexdigest()


def compute_install_hash(state_json: dict, version: str) -> str:
    """Compute hash of cluster configuration to detect changes."""
    cluster_nodes = state_json.get("clusterNodes", [])
    wg_props = state_json.get("wgNodeProperties", [])

    # Build payload from node IDs and their WG addresses
    node_ids = sorted([n["node_id"] for n in cluster_nodes])
    wg_addresses = []

    # Build map of node_id -> tunnel_ip
    tunnel_ip_map = {}
    for prop in wg_props:
        if prop.get("name") == "tunnel_ip":
            tunnel_ip_map[prop.get("node_id")] = prop.get("value")

    for node_id in node_ids:
        hashed_id = hash_node_id(node_id)
        tunnel_ip = tunnel_ip_map.get(node_id, "unknown")
        wg_addresses.append(f"{hashed_id}={tunnel_ip}")

    payload = "|".join(node_ids) + "|" + "|".join(wg_addresses) + "|" + str(COCKROACH_SQL_PORT) + "|" + version
    return hashlib.sha256(payload.encode()).hexdigest()


def get_node_tunnel_ip(node_id: str, wg_props: list) -> str | None:
    """Get WireGuard tunnel IP for a node."""
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def check_all_nodes_have_wg(cluster_nodes: list, wg_props: list) -> bool:
    """Check if all cluster nodes have WireGuard tunnel IPs."""
    for node in cluster_nodes:
        node_id = node.get("node_id")
        if not get_node_tunnel_ip(node_id, wg_props):
            return False
    return True


def is_cluster_initialized(cockroach_props: list) -> bool:
    """Check if cluster is already initialized by any node."""
    for prop in cockroach_props:
        if prop.get("name") == "cockroachdb_cluster_initialized" and prop.get("value") == "true":
            return True
    return False


def get_leader_node(state_json: dict) -> str | None:
    """Get leader node ID from cluster info."""
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def is_cockroach_available() -> bool:
    """Check if CockroachDB binary is available."""
    return os.path.exists(COCKROACH_BIN)


def install_cockroachdb():
    """Install CockroachDB binary."""
    try:
        # Download CockroachDB binary
        if not os.path.exists("/usr/local/bin"):
            os.makedirs("/usr/local/bin", exist_ok=True)

        # Detect architecture
        arch_result = subprocess.run(["uname", "-m"], capture_output=True, text=True)
        arch = arch_result.stdout.strip()

        # Map architecture names
        arch_map = {
            "x86_64": "amd64",
            "aarch64": "arm64",
            "arm64": "arm64"
        }
        cockroach_arch = arch_map.get(arch, "amd64")

        # Download and install
        download_url = f"https://binaries.cockroachdb.com/cockroach-{COCKROACH_VERSION}.linux-{cockroach_arch}.tgz"

        print(f"[*] Downloading CockroachDB from {download_url}", file=sys.stderr)

        result = subprocess.run(
            ["curl", "-L", download_url, "-o", "/tmp/cockroach.tgz"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to download CockroachDB: {result.stderr}")

        # Extract
        result = subprocess.run(
            ["tar", "-xzf", "/tmp/cockroach.tgz", "-C", "/tmp/"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to extract CockroachDB: {result.stderr}")

        # Find the extracted binary
        extracted_dir = f"/tmp/cockroach-{COCKROACH_VERSION}.linux-{cockroach_arch}"
        if not os.path.exists(extracted_dir):
            raise Exception(f"Extracted directory not found: {extracted_dir}")

        # Copy binary
        shutil.copy(f"{extracted_dir}/cockroach", COCKROACH_BIN)
        os.chmod(COCKROACH_BIN, 0o755)

        # Cleanup
        shutil.rmtree(extracted_dir, ignore_errors=True)
        os.remove("/tmp/cockroach.tgz")

        print(f"[*] CockroachDB installed successfully", file=sys.stderr)
    except Exception as e:
        print(f"[!] Failed to install CockroachDB: {e}", file=sys.stderr)
        raise


def create_systemd_service(local_tunnel_ip: str, join_addresses: list):
    """Create systemd service for CockroachDB."""
    service_content = f"""[Unit]
Description=CockroachDB
After=network.target

[Service]
Type=notify
User=root
ExecStart={COCKROACH_BIN} start \\
  --insecure \\
  --advertise-addr={local_tunnel_ip}:{COCKROACH_SQL_PORT} \\
  --listen-addr={local_tunnel_ip}:{COCKROACH_SQL_PORT} \\
  --http-addr={local_tunnel_ip}:{COCKROACH_HTTP_PORT} \\
  --store={COCKROACH_DATA_DIR} \\
  --cache=.25 \\
  --max-sql-memory=.25 \\
  --join={','.join(join_addresses)}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""

    service_path = "/etc/systemd/system/cockroachdb.service"
    with open(service_path, "w") as f:
        f.write(service_content)

    # Reload systemd
    subprocess.run(["systemctl", "daemon-reload"], check=False)


def wait_for_cockroach_ready(local_tunnel_ip: str, timeout_sec: int = 60) -> bool:
    """Wait for CockroachDB process to start and listen on port."""
    start_time = time.time()
    last_error = None

    while time.time() - start_time < timeout_sec:
        try:
            # Check if service is active
            result = subprocess.run(
                ["systemctl", "is-active", "cockroachdb"],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.stdout.strip() != "active":
                last_error = f"Service not active: {result.stdout.strip()}"
                time.sleep(3)
                continue

            # Check if port is listening using nc (netcat)
            result = subprocess.run(
                ["nc", "-z", local_tunnel_ip, str(COCKROACH_SQL_PORT)],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                print(f"[*] CockroachDB process is ready and listening on {local_tunnel_ip}:{COCKROACH_SQL_PORT}", file=sys.stderr)
                return True

            last_error = f"Port not yet listening"
        except subprocess.TimeoutExpired:
            last_error = "Port check timed out"
        except Exception as e:
            last_error = f"Port check error: {str(e)}"

        time.sleep(3)

    print(f"[!] CockroachDB did not become ready within {timeout_sec}s. Last error: {last_error}", file=sys.stderr)
    return False


def is_cockroach_running() -> tuple[bool, str | None]:
    """Check if CockroachDB is running.
    Returns (is_running, error_message)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "cockroachdb"],
            capture_output=True,
            text=True
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def init_cluster(local_tunnel_ip: str) -> bool:
    """Initialize CockroachDB cluster."""
    try:
        result = subprocess.run(
            [COCKROACH_BIN, "init", "--insecure", "--host", f"{local_tunnel_ip}:{COCKROACH_SQL_PORT}"],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            # Check if already initialized
            if "cluster has already been initialized" in result.stderr.lower():
                print(f"[*] Cluster already initialized", file=sys.stderr)
                return True
            print(f"[!] Cluster initialization failed: {result.stderr}", file=sys.stderr)
            return False

        print(f"[*] CockroachDB cluster initialized successfully", file=sys.stderr)
        return True
    except Exception as e:
        print(f"[!] Failed to initialize CockroachDB cluster: {e}", file=sys.stderr)
        return False


def check_node_in_cluster(local_tunnel_ip: str) -> tuple[bool, str | None]:
    """Check if local node is part of the cluster.
    Returns (is_in_cluster, error_message)
    """
    try:
        result = subprocess.run(
            [COCKROACH_BIN, "node", "status", "--insecure", "--host", f"{local_tunnel_ip}:{COCKROACH_SQL_PORT}"],
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            return False, f"Failed to get node status: {result.stderr}"

        # If we can get node status, we're in the cluster
        return True, None
    except Exception as e:
        return False, f"Failed to check cluster status: {str(e)}"


# Plugin commands

@plugin.command('init')
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize CockroachDB: install binary."""
    try:
        # Install CockroachDB if not present
        if not is_cockroach_available():
            install_cockroachdb()

        # Ensure directories exist
        COCKROACH_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        COCKROACH_DATA_DIR.mkdir(parents=True, exist_ok=True)

        return PluginOutput(status='completed', local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=str(e), local_state=input_data.local_state)


@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply CockroachDB configuration and start the cluster."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='error', error_message='Invalid state format', local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    cockroach_props = state_json.get("cockroachNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])
    cluster = state_json.get("cluster", {})

    # Check if all nodes have WireGuard configured
    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        return PluginOutput(
            status='postponed',
            error_message='Waiting for WireGuard to be configured on all nodes',
            local_state=local_state
        )

    # Allow single-node CockroachDB cluster (suitable for dev/single-node setups).
    # Swarm clustering policy still controls desired min/max size; here we are not blocking with len(cluster_nodes) == 1.
    if len(cluster_nodes) < 1:
        return PluginOutput(
            status='postponed',
            error_message=f'CockroachDB cluster requires at least 1 node, currently have {len(cluster_nodes)}',
            local_state=local_state
        )

    # Determine if this is leader node
    leader_node_id = get_leader_node(state_json)
    is_leader = (leader_node_id == local_node_id)
    cluster_initialized = is_cluster_initialized(cockroach_props)

    # Get local tunnel IP
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(
            status='error',
            error_message='Local node has no WireGuard tunnel IP',
            local_state=local_state
        )

    # Compute install hash to detect config changes
    install_hash = compute_install_hash(state_json, COCKROACH_VERSION)

    # Check if we need to reconfigure
    prev_install_hash = local_state.get("install_hash")
    if prev_install_hash == install_hash and local_state.get("cockroach_ready"):
        # No changes, skip reconfiguration
        return PluginOutput(status='completed', local_state=local_state)

    # Build join addresses (all nodes)
    join_addresses = []
    for node in cluster_nodes:
        tunnel_ip = get_node_tunnel_ip(node.get("node_id"), wg_props)
        if tunnel_ip:
            join_addresses.append(f"{tunnel_ip}:{COCKROACH_SQL_PORT}")

    if not join_addresses:
        return PluginOutput(
            status='error',
            error_message='No WireGuard addresses available for cluster nodes',
            local_state=local_state
        )

    # Create systemd service
    try:
        create_systemd_service(local_tunnel_ip, join_addresses)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to create service: {str(e)}', local_state=local_state)

    # Start CockroachDB
    try:
        result = subprocess.run(["systemctl", "enable", "cockroachdb"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to enable CockroachDB: {result.stderr}', local_state=local_state)

        result = subprocess.run(["systemctl", "restart", "cockroachdb"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to start CockroachDB: {result.stderr}', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to start CockroachDB: {str(e)}', local_state=local_state)

    # Wait for CockroachDB to become ready
    cockroach_ready = wait_for_cockroach_ready(local_tunnel_ip, timeout_sec=60)

    if not cockroach_ready:
        return PluginOutput(
            status='postponed',
            error_message='CockroachDB did not become ready within timeout',
            local_state={**local_state, "install_hash": install_hash, "cockroach_ready": False}
        )

    # Update local state
    new_local_state = {
        **local_state,
        "install_hash": install_hash,
        "cockroach_ready": cockroach_ready,
        "is_leader": is_leader
    }

    # If this is the leader node and cluster is not initialized, initialize it
    if is_leader and not cluster_initialized:
        # Wait a bit for all nodes to be ready
        time.sleep(5)

        # Initialize cluster
        if init_cluster(local_tunnel_ip):
            # Mark cluster as initialized
            node_properties = {
                "cockroachdb_cluster_initialized": "true",
                "cockroachdb_node_ready": "true"
            }
            return PluginOutput(
                status='completed',
                node_properties=node_properties,
                local_state=new_local_state
            )
        else:
            return PluginOutput(
                status='postponed',
                error_message='Failed to initialize CockroachDB cluster',
                local_state=new_local_state
            )

    # For non-leader nodes or already initialized cluster
    # Check if node is part of cluster
    if cluster_initialized:
        in_cluster, error = check_node_in_cluster(local_tunnel_ip)
        if in_cluster:
            node_properties = {"cockroachdb_node_ready": "true"}
            return PluginOutput(
                status='completed',
                node_properties=node_properties,
                local_state=new_local_state
            )
        else:
            return PluginOutput(
                status='postponed',
                error_message=f'Node not in cluster yet: {error}',
                local_state=new_local_state
            )

    # Wait for leader to initialize cluster
    return PluginOutput(
        status='postponed',
        error_message=f'Waiting for leader node {leader_node_id} to initialize cluster',
        local_state=new_local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check CockroachDB health."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Check if CockroachDB is running
    cockroach_running, cockroach_error = is_cockroach_running()
    if not cockroach_running:
        if cockroach_error and 'Failed to' in cockroach_error:
            # Real error checking status
            return PluginOutput(status='error', error_message=cockroach_error, local_state=local_state)
        else:
            # Service not running yet
            return PluginOutput(status='postponed', error_message=cockroach_error or 'CockroachDB service is not running', local_state=local_state)

    # Check node status
    wg_props = state_json.get("wgNodeProperties", []) if isinstance(state_json, dict) else []
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)

    if local_tunnel_ip:
        in_cluster, error = check_node_in_cluster(local_tunnel_ip)
        if not in_cluster:
            if error and 'Failed to' in error:
                # Real error
                return PluginOutput(status='error', error_message=error, local_state=local_state)
            else:
                # Not in cluster yet
                return PluginOutput(status='postponed', error_message=error or 'Node not in cluster', local_state=local_state)

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('finalize')
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize before node removal (graceful shutdown)."""
    local_state = input_data.local_state or {}

    # TODO: Implement graceful node removal from cluster if needed
    # This could involve:
    # - Decommissioning the node
    # - Waiting for data replication
    # - Removing node from cluster

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy CockroachDB installation and clean up."""
    try:
        # Stop and disable CockroachDB
        subprocess.run(["systemctl", "stop", "cockroachdb"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "cockroachdb"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Remove systemd service file
        service_path = "/etc/systemd/system/cockroachdb.service"
        if os.path.exists(service_path):
            os.remove(service_path)
        subprocess.run(["systemctl", "daemon-reload"], check=False)

        # Remove config and data directories
        if COCKROACH_CONFIG_DIR.exists():
            shutil.rmtree(COCKROACH_CONFIG_DIR, ignore_errors=True)
        if COCKROACH_DATA_DIR.exists():
            shutil.rmtree(COCKROACH_DATA_DIR, ignore_errors=True)

        # Request deletion of node properties
        node_properties = {
            "cockroachdb_node_ready": None,
            "cockroachdb_cluster_initialized": None,
        }

        return PluginOutput(
            status='completed',
            node_properties=node_properties,
            local_state={}
        )
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to destroy CockroachDB: {e}', local_state={})


if __name__ == "__main__":
    plugin.run()
