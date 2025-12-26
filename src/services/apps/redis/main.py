#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import hashlib
import time
import pwd
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
REDIS_VERSION = os.environ.get("REDIS_VERSION", "7.0")
REDIS_PORT = 6379
REDIS_CONFIG_DIR = Path("/etc/redis")
REDIS_CONFIG_FILE = REDIS_CONFIG_DIR / "redis.conf"
REDIS_DATA_DIR = Path("/var/lib/redis")
REDIS_CLI = "redis-cli"

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions


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


def is_cluster_initialized(redis_props: list) -> bool:
    """Check if cluster is already initialized by any node."""
    for prop in redis_props:
        if prop.get("name") == "redis_cluster_initialized" and prop.get("value") == "true":
            return True
    return False


def check_all_nodes_redis_ready(cluster_nodes: list, redis_props: list) -> bool:
    """Check if all cluster nodes have Redis running and ready."""
    not_ready_nodes = []
    for node in cluster_nodes:
        node_id = node.get("node_id")
        node_ready = False
        for prop in redis_props:
            if (prop.get("node_id") == node_id and
                prop.get("name") == "redis_node_ready" and
                prop.get("value") == "true"):
                node_ready = True
                break
        if not node_ready:
            not_ready_nodes.append(node_id)

    if not_ready_nodes:
        print(f"[*] Nodes not ready yet: {', '.join(not_ready_nodes)}", file=sys.stderr)
        return False

    print(f"[*] All {len(cluster_nodes)} nodes are ready", file=sys.stderr)
    return True


def get_leader_node(state_json: dict) -> str | None:
    """Get leader node ID from cluster info."""
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def is_redis_available() -> bool:
    """Check if Redis binaries are available."""
    return shutil.which("redis-server") is not None


def install_redis():
    """Install Redis using package manager."""
    try:
        # Detect OS
        if not os.path.exists("/etc/os-release"):
            raise Exception("Cannot detect OS: /etc/os-release not found")

        with open("/etc/os-release", "r") as f:
            os_release = f.read()

        # Check for Ubuntu
        if "ubuntu" in os_release.lower():
            # Update package list
            result = subprocess.run(["apt-get", "update"], capture_output=True, text=True)
            if result.returncode != 0:
                raise Exception(f"apt-get update failed: {result.stderr}")

            # Install Redis
            result = subprocess.run(
                ["apt-get", "install", "-y", "redis-server", "redis-tools"],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                raise Exception(f"Redis installation failed: {result.stderr}")
            return

        raise Exception("Unsupported OS for Redis installation")
    except Exception as e:
        print(f"[!] Failed to install Redis: {e}", file=sys.stderr)
        raise

def ensure_redis_directories():
    """Ensure Redis data and log directories exist with correct ownership."""
    REDIS_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    REDIS_DATA_DIR.mkdir(parents=True, exist_ok=True)
    log_dir = Path("/var/log/redis")
    log_dir.mkdir(parents=True, exist_ok=True)

    # Try to set ownership to the redis user if it exists
    try:
        redis_user = pwd.getpwnam("redis")
        uid = redis_user.pw_uid
        gid = redis_user.pw_gid
    except KeyError:
        uid = gid = None

    if uid is not None:
        for path in (REDIS_DATA_DIR, log_dir):
            try:
                os.chown(path, uid, gid)
            except PermissionError:
                # If we cannot change ownership, continue with defaults
                pass

    # Ensure restrictive permissions on data dir
    try:
        REDIS_DATA_DIR.chmod(0o750)
    except PermissionError:
        pass

def write_redis_config(local_node_id: str, local_tunnel_ip: str, cluster_nodes: list, wg_props: list):
    """Write Redis cluster configuration file."""
    ensure_redis_directories()

    REDIS_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    REDIS_DATA_DIR.mkdir(parents=True, exist_ok=True)

    cfg_lines = [
        f"bind {local_tunnel_ip}",
        f"port {REDIS_PORT}",
        "protected-mode no",
        "cluster-enabled yes",
        f"cluster-config-file {REDIS_DATA_DIR}/nodes.conf",
        f"cluster-node-timeout 15000",
        # Persistence: AOF + RDB
        f"appendonly yes",
        "appendfilename appendonly.aof",
        "appendfsync everysec",
        # RDB snapshots
        "save 900 1",      # Save after 900 sec if at least 1 key changed
        "save 300 10",     # Save after 300 sec if at least 10 keys changed
        "save 60 10000",   # Save after 60 sec if at least 10000 keys changed
        "stop-writes-on-bgsave-error yes",
        "rdbcompression yes",
        "rdbchecksum yes",
        "dbfilename dump.rdb",
        f"dir {REDIS_DATA_DIR}",
        "daemonize no",
        "supervised systemd",
        "loglevel notice",
        "logfile /var/log/redis/redis-server.log",
    ]

    REDIS_CONFIG_FILE.write_text("\n".join(cfg_lines) + "\n")


def wait_for_redis_ready(local_tunnel_ip: str, timeout_sec: int = 60) -> bool:
    """Wait for Redis server to become ready."""
    start_time = time.time()
    last_error = None

    while time.time() - start_time < timeout_sec:
        try:
            result = subprocess.run(
                [REDIS_CLI, "-h", local_tunnel_ip, "-p", str(REDIS_PORT), "ping"],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0 and result.stdout.strip() == "PONG":
                return True

            last_error = f"Redis returned: {result.stdout.strip()}"
        except subprocess.TimeoutExpired:
            last_error = "Redis ping timed out"
        except Exception as e:
            last_error = f"Redis ping error: {str(e)}"

        time.sleep(3)

    print(f"[!] Redis did not become ready within {timeout_sec}s. Last error: {last_error}", file=sys.stderr)
    return False


def is_redis_running() -> tuple[bool, str | None]:
    """Check if Redis server is running.
    Returns (is_running, error_message)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "redis-server"],
            capture_output=True,
            text=True
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def create_redis_cluster(cluster_nodes: list, wg_props: list) -> bool:
    """Ensure all Redis nodes form a single replicated cluster with one master shard.

    Behaviour:
    - 1 node  -> initialize a single-node cluster (all slots 0..16383 on that node).
    - N>1     -> same single-node cluster on the first node, all other nodes join
                as replicas of this master (no sharding, no additional masters).
    """
    try:
        # Build list of (node_id, tunnel_ip) for all nodes that have WireGuard IPs
        node_endpoints: list[tuple[str, str]] = []
        for node in cluster_nodes:
            node_id = node.get("node_id")
            tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
            if tunnel_ip:
                node_endpoints.append((node_id, tunnel_ip))

        if not node_endpoints:
            print(f"[!] Need at least 1 node for Redis cluster, got 0", file=sys.stderr)
            return False

        # Use a stable ordering (by node_id) so that the primary master is deterministic.
        node_endpoints.sort(key=lambda x: x[0])

        primary_id, primary_ip = node_endpoints[0]

        # Helper: check if the given endpoint already has a healthy cluster_state=ok.
        def _cluster_state_ok(ip: str) -> bool:
            try:
                result = subprocess.run(
                    [REDIS_CLI, "-h", ip, "-p", str(REDIS_PORT), "cluster", "info"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                if result.returncode != 0:
                    return False
                for line in result.stdout.splitlines():
                    if line.startswith("cluster_state:"):
                        state = line.split(":", 1)[1].strip()
                        return state == "ok"
                return False
            except Exception as e:
                print(f"[!] Failed to read cluster info from {ip}: {e}", file=sys.stderr)
                return False

        # Step 1: ensure the primary master has a valid single-node cluster with all slots.
        if _cluster_state_ok(primary_ip):
            print(f"[*] Primary Redis node {primary_ip} already has cluster_state=ok", file=sys.stderr)
        else:
            cmd = [
                REDIS_CLI,
                "-h",
                primary_ip,
                "-p",
                str(REDIS_PORT),
                "cluster",
                "addslots",
                *[str(i) for i in range(16384)],
            ]

            print(
                f"[*] Initializing single-node Redis cluster on primary {primary_ip} with command: "
                f"redis-cli -h {primary_ip} -p {REDIS_PORT} cluster addslots 0..16383",
                file=sys.stderr,
            )

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,
            )

            if result.returncode != 0:
                # If slots are already assigned, Redis may return "ERR Slot X is already busy".
                stderr_lower = (result.stderr or "").lower()
                stdout_lower = (result.stdout or "").lower()
                if "already busy" in stderr_lower or "already busy" in stdout_lower:
                    if _cluster_state_ok(primary_ip):
                        print(f"[*] Primary {primary_ip} already has all slots assigned and cluster_state=ok", file=sys.stderr)
                    else:
                        print(f"[!] Primary {primary_ip} has slots but cluster_state is not ok", file=sys.stderr)
                        print(f"[!] STDOUT: {result.stdout}", file=sys.stderr)
                        print(f"[!] STDERR: {result.stderr}", file=sys.stderr)
                        return False
                else:
                    print(f"[!] Single-node cluster initialization failed with return code {result.returncode}", file=sys.stderr)
                    print(f"[!] STDOUT: {result.stdout}", file=sys.stderr)
                    print(f"[!] STDERR: {result.stderr}", file=sys.stderr)
                    return False
            else:
                print(f"[*] Single-node Redis cluster initialized successfully on {primary_ip}", file=sys.stderr)
                print(f"[*] Initialization output: {result.stdout}", file=sys.stderr)

        # If there's only one node, we're done.
        if len(node_endpoints) == 1:
            return True

        # Step 2: make all other nodes replicas of the primary master.
        for replica_id, replica_ip in node_endpoints[1:]:
            # If replica is already part of the cluster and cluster_state is ok, skip.
            if _cluster_state_ok(replica_ip):
                print(f"[*] Replica candidate {replica_ip} already has cluster_state=ok, skipping add-node", file=sys.stderr)
                continue

            cmd = [
                REDIS_CLI,
                "--cluster",
                "add-node",
                f"{replica_ip}:{REDIS_PORT}",
                f"{primary_ip}:{REDIS_PORT}",
                "--cluster-slave",
            ]

            print(
                f"[*] Adding replica node {replica_ip} to Redis cluster via primary {primary_ip} "
                f"with command: {' '.join(cmd)}",
                file=sys.stderr,
            )

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,
            )

            if result.returncode != 0:
                stdout_lower = (result.stdout or "").lower()
                stderr_lower = (result.stderr or "").lower()

                already_joined_markers = [
                    "already part of cluster",
                    "already known",
                    "already existing node",
                ]
                if any(m in stdout_lower or m in stderr_lower for m in already_joined_markers):
                    print(f"[*] Node {replica_ip} already part of the cluster, treating as success", file=sys.stderr)
                    continue

                print(f"[!] Failed to add replica node {replica_ip} to cluster (rc={result.returncode})", file=sys.stderr)
                print(f"[!] STDOUT: {result.stdout}", file=sys.stderr)
                print(f"[!] STDERR: {result.stderr}", file=sys.stderr)
                return False

            print(f"[*] Replica node {replica_ip} added to Redis cluster successfully", file=sys.stderr)
            print(f"[*] add-node output: {result.stdout}", file=sys.stderr)

        return True
    except Exception as e:
        print(f"[!] Failed to create or reconcile Redis cluster: {e}", file=sys.stderr)
        import traceback
        print(f"[!] Traceback: {traceback.format_exc()}", file=sys.stderr)
        return False


def check_node_in_cluster(local_tunnel_ip: str) -> tuple[bool, str | None]:
    """Check if local node is part of the cluster.
    Returns (is_in_cluster, error_message)
    """
    try:
        result = subprocess.run(
            [REDIS_CLI, "-h", local_tunnel_ip, "-p", str(REDIS_PORT), "cluster", "info"],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode != 0:
            return False, f"Failed to get cluster info: {result.stderr}"

        output = result.stdout.strip()
        # Check if cluster_state is ok
        for line in output.split('\n'):
            if line.startswith('cluster_state:'):
                state = line.split(':')[1].strip()
                is_ok = state == "ok"
                return is_ok, None if is_ok else f"Cluster state: {state}"

        return False, "Could not determine cluster state"
    except Exception as e:
        return False, f"Failed to check cluster status: {str(e)}"


# Plugin commands

@plugin.command('init')
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize Redis: install packages."""
    try:
        # Install Redis if not present
        if not is_redis_available():
            install_redis()

        # Ensure log directory exists
        Path("/var/log/redis").mkdir(parents=True, exist_ok=True)

        return PluginOutput(status='completed', local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=str(e), local_state=input_data.local_state)


@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply Redis configuration and start the cluster."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='error', error_message='Invalid state format', local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    redis_props = state_json.get("redisNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])
    cluster = state_json.get("cluster", {})

    # Check if all nodes have WireGuard configured
    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        return PluginOutput(
            status='postponed',
            error_message='Waiting for WireGuard to be configured on all nodes',
            local_state=local_state
        )

    # Need at least 1 node for Redis cluster
    if len(cluster_nodes) < 1:
        return PluginOutput(
            status='postponed',
            error_message=f'Redis cluster requires at least 1 node, currently have {len(cluster_nodes)}',
            local_state=local_state
        )

    # Determine if this is leader node
    leader_node_id = get_leader_node(state_json)
    is_leader = (leader_node_id == local_node_id)
    cluster_initialized = is_cluster_initialized(redis_props)

    # Get local tunnel IP
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(
            status='error',
            error_message='Local node has no WireGuard tunnel IP',
            local_state=local_state
        )

    # Write Redis configuration
    try:
        write_redis_config(local_node_id, local_tunnel_ip, cluster_nodes, wg_props)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to write config: {str(e)}', local_state=local_state)

    # Check if we need to restart Redis
    # Read the current config to see if it matches what we just wrote
    needs_restart = False
    redis_running, redis_error = is_redis_running()

    if not redis_running:
        needs_restart = True
    else:
        # Check if Redis is bound to the correct IP
        try:
            # Try to ping Redis on tunnel_ip
            result = subprocess.run(
                [REDIS_CLI, "-h", local_tunnel_ip, "-p", str(REDIS_PORT), "ping"],
                capture_output=True,
                text=True,
                timeout=2
            )
            if result.returncode != 0 or result.stdout.strip() != "PONG":
                # Redis is not responding on tunnel_ip, needs restart
                needs_restart = True
        except:
            needs_restart = True

    if needs_restart:
        # Start/restart Redis server
        try:
            result = subprocess.run(["systemctl", "enable", "redis-server"], capture_output=True, text=True)
            if result.returncode != 0:
                return PluginOutput(status='error', error_message=f'Failed to enable Redis: {result.stderr}', local_state=local_state)

            result = subprocess.run(["systemctl", "restart", "redis-server"], capture_output=True, text=True)
            if result.returncode != 0:
                return PluginOutput(status='error', error_message=f'Failed to start Redis: {result.stderr}', local_state=local_state)
        except Exception as e:
            return PluginOutput(status='error', error_message=f'Failed to start Redis: {str(e)}', local_state=local_state)

        # Wait for Redis to become ready
        redis_ready = wait_for_redis_ready(local_tunnel_ip, timeout_sec=60)

        if not redis_ready:
            return PluginOutput(
                status='postponed',
                error_message='Redis did not become ready within timeout',
                local_state=local_state
            )

    # Cluster leader is responsible for creating/reconciling the Redis cluster (idempotent).
    # This allows new nodes to be automatically added as replicas even after
    # the initial initialization (when redis_cluster_initialized is already "true").
    if is_leader:
        # This node has already started Redis and can be treated as "ready".
        leader_node_properties = {"redis_node_ready": "true"}

        # Wait until all nodes have their local Redis up (mark themselves with redis_node_ready=true).
        if not check_all_nodes_redis_ready(cluster_nodes, redis_props):
            return PluginOutput(
                status='postponed',
                error_message='Waiting for all nodes to have Redis ready before creating/updating cluster',
                node_properties=leader_node_properties,
                local_state=local_state
            )

        # All nodes are ready — create/update the cluster.
        # create_redis_cluster is written to be idempotent: on repeated invocations
        # it does not break an already initialized cluster and only adds
        # missing nodes as replicas.
        if create_redis_cluster(cluster_nodes, wg_props):
            leader_node_properties["redis_cluster_initialized"] = "true"
            return PluginOutput(
                status='completed',
                node_properties=leader_node_properties,
                local_state=local_state
            )
        else:
            return PluginOutput(
                status='postponed',
                error_message='Failed to create or reconcile Redis cluster',
                node_properties=leader_node_properties,
                local_state=local_state
            )

    # For non-leader nodes or already initialized cluster
    # Check if node is part of cluster
    if cluster_initialized:
        in_cluster, error = check_node_in_cluster(local_tunnel_ip)
        if in_cluster:
            node_properties = {"redis_node_ready": "true"}
            return PluginOutput(
                status='completed',
                node_properties=node_properties,
                local_state=local_state
            )
        else:
            # Local Redis is already running, but the node is not yet part of the cluster.
            # We still mark it as "ready" so that the leader can see all ready nodes
            # and add them to the cluster on the next reconciliation run.
            node_properties = {"redis_node_ready": "true"}
            return PluginOutput(
                status='postponed',
                error_message=f'Node not in cluster yet: {error}',
                node_properties=node_properties,
                local_state=local_state
            )

    # Non-leader node: Mark as ready and wait for leader to initialize cluster
    node_properties = {"redis_node_ready": "true"}
    return PluginOutput(
        status='postponed',
        error_message=f'Waiting for leader node {leader_node_id} to initialize cluster',
        node_properties=node_properties,
        local_state=local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check Redis health."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Check if Redis is running
    redis_running, redis_error = is_redis_running()
    if not redis_running:
        if redis_error and 'Failed to' in redis_error:
            # Real error checking status
            return PluginOutput(status='error', error_message=redis_error, local_state=local_state)
        else:
            # Service not running yet
            return PluginOutput(status='postponed', error_message=redis_error or 'Redis service is not running', local_state=local_state)

    # Get local tunnel IP
    wg_props = state_json.get("wgNodeProperties", []) if isinstance(state_json, dict) else []
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)

    if not local_tunnel_ip:
        return PluginOutput(status='postponed', error_message='No tunnel IP available', local_state=local_state)

    # Check Redis ping
    try:
        result = subprocess.run(
            [REDIS_CLI, "-h", local_tunnel_ip, "-p", str(REDIS_PORT), "ping"],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode != 0 or result.stdout.strip() != "PONG":
            return PluginOutput(status='postponed', error_message='Redis is not responding', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='postponed', error_message=f'Failed to ping Redis: {e}', local_state=local_state)

    # Check cluster status
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

    # TODO: Implement graceful node removal from cluster if needed.

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy Redis installation and clean up."""
    try:
        # Stop and disable Redis
        subprocess.run(["systemctl", "stop", "redis-server"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "redis-server"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Remove config and data directories
        if REDIS_CONFIG_DIR.exists():
            shutil.rmtree(REDIS_CONFIG_DIR, ignore_errors=True)
        if REDIS_DATA_DIR.exists():
            shutil.rmtree(REDIS_DATA_DIR, ignore_errors=True)

        # Request deletion of node properties
        node_properties = {
            "redis_node_ready": None,
            "redis_cluster_initialized": None,
        }

        return PluginOutput(
            status='completed',
            node_properties=node_properties,
            local_state={}
        )
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to destroy Redis: {e}', local_state={})


if __name__ == "__main__":
    plugin.run()
