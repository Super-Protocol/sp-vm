#!/usr/bin/env python3

import json
import sys
import time
from typing import List, Tuple, Optional

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput


ROUTE_DOMAIN = "test.test.oresty.superprotocol.io"
ROUTE_KEY = f"routes:{ROUTE_DOMAIN}"
APP_PORT = 34567


plugin = ProvisionPlugin()


def get_node_tunnel_ip(node_id: str, wg_props: list) -> Optional[str]:
    """Get WireGuard tunnel IP for a node."""
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def get_leader_node(state_json: dict) -> Optional[str]:
    """Get leader node ID from cluster info."""
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def is_local_node_leader(local_node_id: str, state_json: dict) -> bool:
    """Check if the local node is the cluster leader."""
    return get_leader_node(state_json) == local_node_id


def get_redis_connection_info(state_json: dict) -> List[Tuple[str, int]]:
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
    endpoints: List[Tuple[str, int]] = []
    for node_id in ready_nodes:
        tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
        if tunnel_ip:
            endpoints.append((tunnel_ip, 6379))

    return endpoints


def is_redis_cluster_initialized(state_json: dict) -> bool:
    """Check whether Redis cluster has been initialized by Redis service plugin.

    Looks for redis_cluster_initialized == "true" in redisNodeProperties.
    """
    redis_props = state_json.get("redisNodeProperties", [])
    for prop in redis_props:
        if (
            prop.get("name") == "redis_cluster_initialized"
            and prop.get("value") == "true"
        ):
            return True
    return False


def ensure_route_in_redis(state_json: dict) -> Tuple[bool, str | None]:
    """Create or update the OpenResty route in Redis Cluster.

    Targets are derived from Swarm state:
    - For each node in the test-app cluster (clusterNodes),
      we find its WireGuard tunnel IP via wgNodeProperties.
    - Each such IP becomes a backend URL http://<ip>:APP_PORT.
    """
    # Ensure Redis cluster is fully initialized (all slots assigned, cluster_state=ok)
    if not is_redis_cluster_initialized(state_json):
        msg = "Redis cluster is not initialized yet"
        print(f"[!] {msg}", file=sys.stderr)
        return False, msg

    endpoints = get_redis_connection_info(state_json)
    if not endpoints:
        msg = "No Redis endpoints available"
        print(f"[!] {msg}", file=sys.stderr)
        return False, msg

    cluster_nodes = state_json.get("clusterNodes", [])
    wg_props = state_json.get("wgNodeProperties", [])

    # Collect tunnel IPs of all nodes that run test-app
    tunnel_ips: List[str] = []
    for node in cluster_nodes:
        node_id = node.get("node_id")
        ip = get_node_tunnel_ip(node_id, wg_props)
        if ip:
            tunnel_ips.append(ip)

    if not tunnel_ips:
        msg = "No WireGuard tunnel IPs available for test-app nodes"
        print(f"[!] {msg}", file=sys.stderr)
        return False, msg

    try:
        import redis
        from redis.cluster import ClusterNode
    except ImportError:
        return False, "redis-py library not installed"

    startup_nodes = [ClusterNode(host, port) for host, port in endpoints]

    # A few retries in case the cluster is still converging or there are
    # short-lived connectivity issues.
    max_retries = 3
    retry_delay_sec = 5
    last_error: str | None = None

    for attempt in range(1, max_retries + 1):
        try:
            print(
                f"[*] Attempt {attempt}/{max_retries} to set route {ROUTE_KEY} "
                f"in Redis Cluster via startup_nodes={startup_nodes}",
                file=sys.stderr,
            )

            r = redis.RedisCluster(
                startup_nodes=startup_nodes,
                decode_responses=True,
                skip_full_coverage_check=True,
                socket_connect_timeout=5,
            )
            r.ping()

            route_config = {
                "targets": [
                    {"url": f"http://{ip}:{APP_PORT}", "weight": 1}
                    for ip in tunnel_ips
                ],
                "policy": "rr",
                "preserve_host": False,
            }

            r.set(ROUTE_KEY, json.dumps(route_config))
            print(
                f"[*] Successfully set route {ROUTE_KEY} -> {json.dumps(route_config)} "
                f"in Redis Cluster on attempt {attempt}",
                file=sys.stderr,
            )
            return True, None
        except Exception as e:
            last_error = f"Failed to write route to Redis Cluster on attempt {attempt}: {e}"
            print(f"[!] {last_error}", file=sys.stderr)

            if attempt < max_retries:
                time.sleep(retry_delay_sec)

    # All attempts failed
    return False, last_error or "Failed to write route to Redis Cluster after retries"


def delete_route_from_redis(state_json: dict) -> Tuple[bool, str | None]:
    """Delete the OpenResty route from Redis Cluster."""
    endpoints = get_redis_connection_info(state_json)
    if not endpoints:
        return False, "No Redis endpoints available"

    try:
        import redis
        from redis.cluster import ClusterNode
    except ImportError:
        return False, "redis-py library not installed"

    startup_nodes = [ClusterNode(host, port) for host, port in endpoints]

    try:
        r = redis.RedisCluster(
            startup_nodes=startup_nodes,
            decode_responses=True,
            skip_full_coverage_check=True,
            socket_connect_timeout=5,
        )
        r.delete(ROUTE_KEY)
        print(f"[*] Deleted route {ROUTE_KEY} from Redis Cluster", file=sys.stderr)
        return True, None
    except Exception as e:
        error_msg = f"Failed to delete route from Redis Cluster: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return False, error_msg


@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """No-op init for test-app-route service."""
    local_state = input_data.local_state or {}
    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Create the Redis route for test-app on the leader node only."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    if not isinstance(state_json, dict):
        return PluginOutput(
            status="error",
            error_message="Invalid state format",
            local_state=local_state,
        )

    # Only leader node should write the route
    if not is_local_node_leader(local_node_id, state_json):
        return PluginOutput(
            status="completed",
            local_state=local_state,
        )

    success, error = ensure_route_in_redis(state_json)
    if not success:
        # Also log the error locally so it shows up in node logs even if
        # the executor does not print error_message from PluginOutput.
        if error:
            print(f"[!] test-app-route apply: {error}", file=sys.stderr)
        return PluginOutput(
            status="postponed",
            error_message=error or "Failed to configure route in Redis",
            local_state=local_state,
        )

    node_properties = {"test_app_route_configured": "true"}
    return PluginOutput(
        status="completed",
        node_properties=node_properties,
        local_state=local_state,
    )


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Leader can optionally verify that the route exists; others are no-op."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    if not isinstance(state_json, dict):
        return PluginOutput(
            status="error",
            error_message="Invalid state format",
            local_state=local_state,
        )

    if not is_local_node_leader(local_node_id, state_json):
        # Non-leader nodes do not manage this route
        return PluginOutput(status="completed", local_state=local_state)

    # Route health makes sense only after Redis cluster is fully initialized
    if not is_redis_cluster_initialized(state_json):
        return PluginOutput(
            status="postponed",
            error_message="Redis cluster is not initialized yet",
            local_state=local_state,
        )

    try:
        import redis
        from redis.cluster import ClusterNode
    except ImportError:
        # If library is missing, health is postponed rather than fatal
        return PluginOutput(
            status="postponed",
            error_message="redis-py library not installed",
            local_state=local_state,
        )

    endpoints = get_redis_connection_info(state_json)
    if not endpoints:
        return PluginOutput(
            status="postponed",
            error_message="No Redis endpoints available",
            local_state=local_state,
        )

    startup_nodes = [ClusterNode(host, port) for host, port in endpoints]

    try:
        r = redis.RedisCluster(
            startup_nodes=startup_nodes,
            decode_responses=True,
            skip_full_coverage_check=True,
            socket_connect_timeout=5,
        )
        value = r.get(ROUTE_KEY)
        if not value:
            return PluginOutput(
                status="postponed",
                error_message=f"Route {ROUTE_KEY} not found in Redis",
                local_state=local_state,
            )
    except Exception as e:
        return PluginOutput(
            status="postponed",
            error_message=f"Failed to verify route in Redis: {e}",
            local_state=local_state,
        )

    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """No special finalize logic required."""
    local_state = input_data.local_state or {}
    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """On leader node, remove the route from Redis."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Only leader attempts to clean up the route
    if isinstance(state_json, dict) and is_local_node_leader(local_node_id, state_json):
        delete_route_from_redis(state_json)

    node_properties = {
        "test_app_route_configured": None,
    }
    return PluginOutput(
        status="completed",
        node_properties=node_properties,
        local_state=local_state,
    )


if __name__ == "__main__":
    plugin.run()
