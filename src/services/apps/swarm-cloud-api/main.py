#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import time
import json
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
API_INSTALL_DIR = Path("/opt/swarm-cloud-api")
API_CONFIG_DIR = Path("/etc/swarm-cloud-api")
API_CONFIG_FILE = API_CONFIG_DIR / "config.yaml"
API_BIN = API_INSTALL_DIR / "swarm-cloud-api"
API_PORT = 3000

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


def get_leader_node(state_json: dict) -> str | None:
    """Get leader node ID from cluster info."""
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def is_local_node_leader(local_node_id: str, state_json: dict) -> bool:
    """Check if local node is the leader."""
    leader_node_id = get_leader_node(state_json)
    return leader_node_id == local_node_id


def is_api_installed() -> bool:
    """Check if swarm-cloud-api is installed."""
    return API_BIN.exists() and os.access(API_BIN, os.X_OK)


def install_swarm_cloud_api():
    """Install swarm-cloud-api binary using system installation script."""
    try:
        install_script = "/usr/local/bin/install-swarm-cloud-api.sh"
        if not os.path.exists(install_script):
            raise Exception(f"Installation script not found: {install_script}")

        print(f"[*] Running installation script: {install_script}", file=sys.stderr)
        result = subprocess.run(
            [install_script],
            capture_output=True,
            text=True,
            timeout=600  # 10 minutes timeout
        )

        if result.returncode != 0:
            raise Exception(f"Installation script failed: {result.stderr}")

        print(result.stdout, file=sys.stderr)
        print(f"[*] Swarm-cloud-api installed successfully", file=sys.stderr)
    except subprocess.TimeoutExpired:
        raise Exception("Installation script timed out after 10 minutes")
    except Exception as e:
        print(f"[!] Failed to install swarm-cloud-api: {e}", file=sys.stderr)
        raise


def get_cockroach_connection_info(local_node_id: str, state_json: dict) -> dict | None:
    """Get CockroachDB connection info, preferring local node.
    Returns dict with host, port, username, database or None if no nodes available.
    """
    cockroach_nodes = state_json.get("cockroachClusterNodes", [])
    cockroach_props = state_json.get("cockroachNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    # Check which nodes have CockroachDB ready
    ready_nodes = set()
    for prop in cockroach_props:
        if prop.get("name") == "cockroachdb_node_ready" and prop.get("value") == "true":
            ready_nodes.add(prop.get("node_id"))

    # Try local node first if available
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if local_node_id in ready_nodes and local_tunnel_ip:
        return {
            "host": local_tunnel_ip,
            "port": 26257,
            "username": "root",
            "database": "defaultdb"
        }

    # Try other nodes
    for node in cockroach_nodes:
        node_id = node.get("node_id")
        if node_id not in ready_nodes:
            continue
        tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
        if tunnel_ip:
            return {
                "host": tunnel_ip,
                "port": 26257,
                "username": "root",
                "database": "defaultdb"
            }

    return None


def create_config_file(local_node_id: str, state_json: dict):
    """Create configuration file for swarm-cloud-api."""
    is_leader = is_local_node_leader(local_node_id, state_json)
    cockroach_info = get_cockroach_connection_info(local_node_id, state_json)

    if not cockroach_info:
        raise Exception("No CockroachDB nodes available")

    config_content = f"""port: {API_PORT}
host: 0.0.0.0

db:
  type: postgresql
  config:
    host: {cockroach_info['host']}
    port: {cockroach_info['port']}
    username: {cockroach_info['username']}
    password: ""
    database: {cockroach_info['database']}
    synchronize: false
    autoLoadEntities: true
    logging: false

swarmDb:
  host: localhost
  port: 3306
  username: root
  password: ""
  database: swarmdb
  synchronize: false
  autoLoadEntities: true
  logging: false

validClientOrigins:
  - http://localhost:3000
  - http://localhost:3001

workers:
  networkSync:
    enabled: {str(is_leader).lower()}
    syncInterval: 10000
  domainVerification:
    enabled: {str(is_leader).lower()}
    checkInterval: 10000
  ingressSync:
    enabled: {str(is_leader).lower()}
    checkInterval: 10000
  gatewaySync:
    enabled: {str(is_leader).lower()}
    checkInterval: 10000
"""

    API_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(API_CONFIG_FILE, "w") as f:
        f.write(config_content)

    print(f"[*] Configuration file created at {API_CONFIG_FILE}", file=sys.stderr)
    print(f"[*] Workers enabled: {is_leader} (leader: {is_leader})", file=sys.stderr)


def create_systemd_service():
    """Create systemd service for swarm-cloud-api."""
    service_content = f"""[Unit]
Description=Swarm Cloud API Service
After=network.target

[Service]
Type=simple
WorkingDirectory={API_INSTALL_DIR}
ExecStart={API_BIN}
Restart=always
RestartSec=10
User=root
Environment="NODE_ENV=production"
Environment="SWC_API_CONFIG_PATH={API_CONFIG_FILE}"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""

    service_path = "/etc/systemd/system/swarm-cloud-api.service"
    with open(service_path, "w") as f:
        f.write(service_content)

    # Reload systemd
    subprocess.run(["systemctl", "daemon-reload"], check=False)


def wait_for_api_ready(timeout_sec: int = 60) -> bool:
    """Wait for API to start and listen on port."""
    start_time = time.time()
    last_error = None

    while time.time() - start_time < timeout_sec:
        try:
            # Check if service is active
            result = subprocess.run(
                ["systemctl", "is-active", "swarm-cloud-api"],
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
                ["nc", "-z", "localhost", str(API_PORT)],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                print(f"[*] Swarm-cloud-api is ready and listening on port {API_PORT}", file=sys.stderr)
                return True

            last_error = f"Port not yet listening"
        except subprocess.TimeoutExpired:
            last_error = "Port check timed out"
        except Exception as e:
            last_error = f"Port check error: {str(e)}"

        time.sleep(3)

    print(f"[!] Swarm-cloud-api did not become ready within {timeout_sec}s. Last error: {last_error}", file=sys.stderr)
    return False


def is_api_running() -> tuple[bool, str | None]:
    """Check if swarm-cloud-api is running.
    Returns (is_running, error_message)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "swarm-cloud-api"],
            capture_output=True,
            text=True
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def get_redis_connection_info(state_json: dict) -> list[tuple[str, int]]:
    """Get Redis cluster connection endpoints.
    Returns list of (host, port) tuples for Redis nodes.
    """
    redis_props = state_json.get("redisNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    # Find ready Redis nodes
    ready_nodes = set()
    for prop in redis_props:
        if prop.get("name") == "redis_node_ready" and prop.get("value") == "true":
            ready_nodes.add(prop.get("node_id"))

    # Get tunnel IPs for ready nodes
    endpoints = []
    for node_id in ready_nodes:
        tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
        if tunnel_ip:
            endpoints.append((tunnel_ip, 6379))

    return endpoints


def get_knot_tunnel_ips(state_json: dict) -> list[str]:
    """Get tunnel IPs of all ready Knot DNS nodes."""
    knot_node_props = state_json.get("knotNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    knot_hosts = []
    for prop in knot_node_props:
        if prop.get("name") == "knot_node_ready" and prop.get("value") == "true":
            node_id = prop.get("node_id")
            tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
            if tunnel_ip:
                knot_hosts.append(tunnel_ip)

    return sorted(set(knot_hosts))


def get_secret_from_swarmdb(state_json: dict, secret_id: str) -> str | None:
    """Get secret value from SwarmSecrets table."""
    secrets = state_json.get("swarmSecrets", [])
    for secret in secrets:
        if secret.get("id") == secret_id:
            return secret.get("value")
    return None


def send_dns_update(
    knot_server: str,
    zone_name: str,
    hostname: str,
    record_type: str,
    records: list[str],
    tsig_key_name: str,
    tsig_key_secret: str,
    ttl: int = 300
) -> bool:
    """Send RFC 2136 DNS UPDATE to Knot server using nsupdate with TSIG authentication.

    Args:
        knot_server: IP address of Knot DNS server
        zone_name: Zone name (e.g., "g5ebqqpj740uhqtu.swarm.anthrax63.fun")
        hostname: Hostname to update (e.g., "api.g5ebqqpj740uhqtu.swarm.anthrax63.fun")
        record_type: Record type (A, AAAA, CNAME, etc.)
        records: List of record values
        tsig_key_name: TSIG key name for authentication
        tsig_key_secret: TSIG key secret (base64)
        ttl: TTL in seconds

    Returns:
        True if update was successful, False otherwise
    """
    try:
        # Build nsupdate script with TSIG authentication
        nsupdate_script = f"""server {knot_server}
key hmac-sha256:{tsig_key_name} {tsig_key_secret}
zone {zone_name}.
update delete {hostname}. {record_type}
"""
        # Then add new records
        for record in records:
            nsupdate_script += f"update add {hostname}. {ttl} {record_type} {record}\n"

        nsupdate_script += "send\n"

        print(f"[*] Sending DNS UPDATE to {knot_server} for {hostname} {record_type} (TSIG: {tsig_key_name})", file=sys.stderr)

        # Execute nsupdate
        result = subprocess.run(
            ["nsupdate"],
            input=nsupdate_script,
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            print(f"[!] nsupdate failed: {result.stderr}", file=sys.stderr)
            return False

        print(f"[*] Successfully updated DNS: {hostname} {record_type} -> {records}", file=sys.stderr)
        return True

    except subprocess.TimeoutExpired:
        print(f"[!] nsupdate timed out", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[!] Failed to send DNS UPDATE: {e}", file=sys.stderr)
        import traceback
        print(f"[!] Traceback: {traceback.format_exc()}", file=sys.stderr)
        return False


def get_knot_tsig_key(state_json: dict) -> tuple[str, str] | None:
    """Get TSIG key from Knot cluster properties.

    Returns:
        (tsig_key_name, tsig_key_secret) tuple or None if not found
    """
    knot_cluster = state_json.get("knotCluster", {})
    if not knot_cluster.get("id"):
        return None

    knot_props = state_json.get("knotClusterProperties", [])

    tsig_key_name = None
    tsig_key_secret = None

    for prop in knot_props:
        if prop.get("name") == "knot_tsig_key_name":
            tsig_key_name = prop.get("value")
        elif prop.get("name") == "knot_tsig_key_secret":
            tsig_key_secret = prop.get("value")

    if tsig_key_name and tsig_key_secret:
        return (tsig_key_name, tsig_key_secret)

    return None


def update_api_dns_and_routing(
    cluster_nodes: list,
    wg_props: list,
    global_id: str,
    base_domain: str,
    knot_tunnel_ips: list[str],
    redis_endpoints: list[tuple[str, int]],
    tsig_key_name: str,
    tsig_key_secret: str
) -> tuple[bool, str | None]:
    """Update DNS CNAME record and OpenResty routing for API service.

    Creates:
    1. CNAME record: api.<global_id>.<base_domain> -> gw.<global_id>.<base_domain>
    2. OpenResty route: api.<global_id>.<base_domain> -> internal tunnel IPs

    Args:
        cluster_nodes: List of API cluster nodes
        wg_props: WireGuard node properties with tunnel IPs
        global_id: Swarm global ID
        base_domain: Base domain from secrets
        knot_tunnel_ips: List of Knot DNS server tunnel IPs
        redis_endpoints: List of (host, port) tuples for Redis cluster
        tsig_key_name: TSIG key name for DNS UPDATE authentication
        tsig_key_secret: TSIG key secret (base64)

    Returns:
        (success, error_message)
    """
    if not global_id or not base_domain:
        return False, "Missing global_id or base_domain"

    if not cluster_nodes:
        return False, "No cluster nodes available"

    if not knot_tunnel_ips:
        return False, "No Knot DNS servers available"

    if not redis_endpoints:
        return False, "No Redis endpoints available"

    try:
        import redis
        from redis.cluster import ClusterNode
        import json
    except ImportError:
        return False, "redis-py library not installed"

    # Full zone and domain names
    full_zone_name = f"{global_id}.{base_domain}"
    api_domain = f"api.{full_zone_name}"
    gw_domain = f"gw.{full_zone_name}"

    # Collect tunnel IPs for all API nodes
    tunnel_ips = []
    for node in cluster_nodes:
        node_id = node.get("node_id")
        tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
        if tunnel_ip:
            tunnel_ips.append(tunnel_ip)

    if not tunnel_ips:
        return False, "No tunnel IPs available for API nodes"

    print(f"[*] Updating DNS and routing for {api_domain}", file=sys.stderr)
    print(f"[*] CNAME: {api_domain} -> {gw_domain}", file=sys.stderr)
    print(f"[*] Route targets: {tunnel_ips}", file=sys.stderr)

    # 1. Create CNAME record in Knot DNS via DNS UPDATE
    knot_server = knot_tunnel_ips[0]
    cname_success = send_dns_update(
        knot_server=knot_server,
        zone_name=full_zone_name,
        hostname=api_domain,
        record_type="CNAME",
        records=[f"{gw_domain}."],
        tsig_key_name=tsig_key_name,
        tsig_key_secret=tsig_key_secret,
        ttl=300
    )

    if not cname_success:
        return False, "Failed to create CNAME record via DNS UPDATE"

    # 2. Create OpenResty route in Redis
    # Connect to Redis Cluster
    startup_nodes = [ClusterNode(host, port) for host, port in redis_endpoints]
    try:
        r = redis.RedisCluster(
            startup_nodes=startup_nodes,
            decode_responses=True,
            skip_full_coverage_check=True,
            socket_connect_timeout=5
        )
        r.ping()

        # Create OpenResty route
        # Format: routes:<domain>
        route_key = f"routes:{api_domain}"
        route_config = {
            "targets": [
                {"url": f"http://{ip}:{API_PORT}", "weight": 1}
                for ip in tunnel_ips
            ],
            "policy": "rr",  # round-robin
            "preserve_host": True
        }
        r.set(route_key, json.dumps(route_config))
        print(f"[*] Created OpenResty route for {api_domain}", file=sys.stderr)

        print(f"[*] Successfully updated DNS and routing", file=sys.stderr)
        return True, None

    except Exception as e:
        error_msg = f"Failed to update Redis Cluster routing: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return False, error_msg


# Plugin commands

@plugin.command('init')
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize swarm-cloud-api: install binary."""
    try:
        # Install swarm-cloud-api if not present
        if not is_api_installed():
            install_swarm_cloud_api()
    except Exception as e:
        return PluginOutput(status='error', error_message=str(e), local_state=input_data.local_state)

    # Create systemd service
    try:
        create_systemd_service()
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to create service: {str(e)}', local_state=local_state)
    
    return PluginOutput(status='completed', local_state=input_data.local_state)


def initialize_schema_if_needed(local_node_id: str, state_json: dict) -> tuple[bool, str | None]:
    """Initialize database schema if not already done.
    Returns (success, error_message).
    """
    # Check if schema is already initialized (from cluster properties in state)
    cluster_properties = state_json.get("clusterProperties", [])
    schema_initialized = any(
        prop.get("name") == "swarm_cloud_api_schema_initialized" and prop.get("value") == "true"
        for prop in cluster_properties
    )

    if schema_initialized:
        print(f"[*] Database schema already initialized", file=sys.stderr)
        return True, None

    # Only leader should initialize schema
    is_leader = is_local_node_leader(local_node_id, state_json)
    if not is_leader:
        print(f"[*] Not a leader, skipping schema initialization", file=sys.stderr)
        return False, "Waiting for leader to initialize schema"

    print(f"[*] Leader node, initializing database schema...", file=sys.stderr)

    # Get CockroachDB connection info
    cockroach_info = get_cockroach_connection_info(local_node_id, state_json)
    if not cockroach_info:
        return False, "No CockroachDB connection available"

    # Set environment variables for schema sync script
    env = os.environ.copy()
    env["DB_TYPE"] = "postgres"
    env["DB_HOST"] = cockroach_info["host"]
    env["DB_PORT"] = str(cockroach_info["port"])
    env["DB_USERNAME"] = cockroach_info["username"]
    env["DB_PASSWORD"] = cockroach_info.get("password", "")
    env["DB_DATABASE"] = cockroach_info["database"]

    # Run schema sync using the schema-sync executable
    try:
        # Path to the schema-sync executable script
        schema_sync_script = API_INSTALL_DIR / "schema-sync"
        if not schema_sync_script.exists():
            return False, f"Schema sync script not found: {schema_sync_script}"

        print(f"[*] Running schema sync script: {schema_sync_script}", file=sys.stderr)
        result = subprocess.run(
            [str(schema_sync_script)],
            env=env,
            capture_output=True,
            text=True,
            timeout=300  # 5 minutes timeout
        )

        if result.returncode != 0:
            error_msg = f"Schema sync failed: {result.stderr}"
            print(f"[!] {error_msg}", file=sys.stderr)
            return False, error_msg

        print(result.stdout, file=sys.stderr)
        print(f"[*] Database schema initialized successfully", file=sys.stderr)
        return True, None

    except subprocess.TimeoutExpired:
        return False, "Schema sync timed out after 5 minutes"
    except Exception as e:
        return False, f"Schema sync error: {str(e)}"


@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply swarm-cloud-api configuration and start the service."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='error', error_message='Invalid state format', local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    wg_props = state_json.get("wgNodeProperties", [])
    cockroach_cluster = state_json.get("cockroachCluster", {})
    cockroach_nodes = state_json.get("cockroachClusterNodes", [])
    cockroach_props = state_json.get("cockroachNodeProperties", [])

    # Check if all nodes have WireGuard configured
    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        return PluginOutput(
            status='postponed',
            error_message='Waiting for WireGuard to be configured on all nodes',
            local_state=local_state
        )

    # Check if CockroachDB cluster exists
    if not cockroach_cluster.get("id"):
        return PluginOutput(
            status='postponed',
            error_message='Waiting for CockroachDB cluster to be created',
            local_state=local_state
        )

    # Check if at least one CockroachDB node is ready
    ready_cockroach_nodes = [
        prop for prop in cockroach_props
        if prop.get("name") == "cockroachdb_node_ready" and prop.get("value") == "true"
    ]

    if not ready_cockroach_nodes:
        return PluginOutput(
            status='postponed',
            error_message='Waiting for at least one CockroachDB node to be ready',
            local_state=local_state
        )

    # Initialize database schema if needed (only on leader, only once)
    schema_success, schema_error = initialize_schema_if_needed(local_node_id, state_json)
    if not schema_success:
        return PluginOutput(
            status='postponed',
            error_message=schema_error or 'Waiting for schema initialization',
            local_state=local_state
        )

    # Create configuration file
    try:
        create_config_file(local_node_id, state_json)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to create config: {str(e)}', local_state=local_state)

    # Start swarm-cloud-api
    try:
        result = subprocess.run(["systemctl", "enable", "swarm-cloud-api"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to enable swarm-cloud-api: {result.stderr}', local_state=local_state)

        result = subprocess.run(["systemctl", "restart", "swarm-cloud-api"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to start swarm-cloud-api: {result.stderr}', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to start swarm-cloud-api: {str(e)}', local_state=local_state)

    # Wait for API to become ready
    api_ready = wait_for_api_ready(timeout_sec=60)

    if not api_ready:
        return PluginOutput(
            status='postponed',
            error_message='Swarm-cloud-api did not become ready within timeout',
            local_state=local_state
        )

    # Prepare properties to return
    node_properties = {"swarm_cloud_api_node_ready": "true"}
    cluster_properties = {}

    # If we are the leader and schema was just initialized, mark it in cluster properties
    is_leader = is_local_node_leader(local_node_id, state_json)
    cluster_props = state_json.get("clusterProperties", [])
    schema_already_marked = any(
        prop.get("name") == "swarm_cloud_api_schema_initialized" and prop.get("value") == "true"
        for prop in cluster_props
    )

    if is_leader and not schema_already_marked:
        cluster_properties["swarm_cloud_api_schema_initialized"] = "true"

    # Leader node updates DNS and routing
    if is_leader:
        global_id = state_json.get("globalId")
        base_domain = get_secret_from_swarmdb(state_json, "base_domain")
        redis_cluster = state_json.get("redisCluster", {})
        knot_cluster = state_json.get("knotCluster", {})

        # Only update if we have required data
        if global_id and base_domain and redis_cluster.get("id") and knot_cluster.get("id"):
            redis_endpoints = get_redis_connection_info(state_json)
            knot_tunnel_ips = get_knot_tunnel_ips(state_json)
            tsig_result = get_knot_tsig_key(state_json)

            if redis_endpoints and knot_tunnel_ips and tsig_result:
                tsig_key_name, tsig_key_secret = tsig_result

                dns_success, dns_error = update_api_dns_and_routing(
                    cluster_nodes,
                    wg_props,
                    global_id,
                    base_domain,
                    knot_tunnel_ips,
                    redis_endpoints,
                    tsig_key_name,
                    tsig_key_secret
                )

                if not dns_success:
                    print(f"[!] Failed to update DNS and routing: {dns_error}", file=sys.stderr)
                    # Don't fail the whole apply, just log the warning
                else:
                    print(f"[*] Successfully updated API DNS and routing", file=sys.stderr)
            else:
                if not redis_endpoints:
                    print(f"[!] No Redis endpoints available for routing update", file=sys.stderr)
                if not knot_tunnel_ips:
                    print(f"[!] No Knot DNS servers available for DNS update", file=sys.stderr)
                if not tsig_result:
                    print(f"[!] No TSIG key available from Knot cluster for DNS update", file=sys.stderr)
        else:
            print(f"[!] Missing required data for DNS update (global_id, base_domain, redis_cluster, or knot_cluster)", file=sys.stderr)

    return PluginOutput(
        status='completed',
        node_properties=node_properties,
        cluster_properties=cluster_properties if cluster_properties else None,
        local_state=local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check swarm-cloud-api health."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Check if API is running
    api_running, api_error = is_api_running()
    if not api_running:
        if api_error and 'Failed to' in api_error:
            # Real error checking status
            return PluginOutput(status='error', error_message=api_error, local_state=local_state)
        else:
            # Service not running yet
            return PluginOutput(status='postponed', error_message=api_error or 'Swarm-cloud-api service is not running', local_state=local_state)

    # If leader node, verify route exists in Redis
    is_leader = is_local_node_leader(local_node_id, state_json)

    if is_leader and isinstance(state_json, dict):
        global_id = state_json.get("globalId")
        base_domain = get_secret_from_swarmdb(state_json, "base_domain")
        redis_endpoints = get_redis_connection_info(state_json)

        if global_id and base_domain and redis_endpoints:
            try:
                import redis
                from redis.cluster import ClusterNode

                full_zone_name = f"{global_id}.{base_domain}"
                api_domain = f"api.{full_zone_name}"
                route_key = f"routes:{api_domain}"

                # Check if route exists in Redis Cluster
                startup_nodes = [ClusterNode(host, port) for host, port in redis_endpoints]
                try:
                    r = redis.RedisCluster(
                        startup_nodes=startup_nodes,
                        decode_responses=True,
                        skip_full_coverage_check=True,
                        socket_connect_timeout=5
                    )
                    r.ping()

                    # Check route
                    route_value = r.get(route_key)
                    if not route_value:
                        print(f"[!] Warning: Route for {api_domain} not found in Redis", file=sys.stderr)
                    else:
                        print(f"[*] Route for {api_domain} verified", file=sys.stderr)

                except Exception as e:
                    print(f"[!] Could not verify route in Redis Cluster: {e}", file=sys.stderr)

            except ImportError:
                pass  # Redis library not available, skip check
            except Exception as e:
                print(f"[!] Error verifying route: {e}", file=sys.stderr)

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('finalize')
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize before node removal (graceful shutdown)."""
    local_state = input_data.local_state or {}

    # Stop the service gracefully
    try:
        subprocess.run(["systemctl", "stop", "swarm-cloud-api"], check=False)
    except Exception as e:
        print(f"[!] Failed to stop swarm-cloud-api: {e}", file=sys.stderr)

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy swarm-cloud-api installation and clean up."""
    try:
        # Stop and disable service
        subprocess.run(["systemctl", "stop", "swarm-cloud-api"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "swarm-cloud-api"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Remove systemd service file
        service_path = "/etc/systemd/system/swarm-cloud-api.service"
        if os.path.exists(service_path):
            os.remove(service_path)
        subprocess.run(["systemctl", "daemon-reload"], check=False)

        # Remove config directory
        if API_CONFIG_DIR.exists():
            shutil.rmtree(API_CONFIG_DIR, ignore_errors=True)

        # Remove installation directory
        if API_INSTALL_DIR.exists():
            shutil.rmtree(API_INSTALL_DIR, ignore_errors=True)

        # Request deletion of node properties
        node_properties = {
            "swarm_cloud_api_node_ready": None,
        }

        return PluginOutput(
            status='completed',
            node_properties=node_properties,
            local_state={}
        )
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to destroy swarm-cloud-api: {e}', local_state={})


if __name__ == "__main__":
    plugin.run()
