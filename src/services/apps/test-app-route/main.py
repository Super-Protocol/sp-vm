#!/usr/bin/env python3

import json
import sys
import time
from typing import List, Tuple, Optional

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput


ROUTE_DOMAIN = "test.test.oresty.superprotocol.io"
ROUTE_KEY = f"manual-routes:{ROUTE_DOMAIN}"
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


def get_sentinel_connection_info(state_json: dict) -> List[Tuple[str, int]]:
    """Get Redis Sentinel connection endpoints."""
    sentinel_props = state_json.get("sentinelNodeProperties", [])
    wg_props = state_json.get("sentinelWgNodeProperties", []) or state_json.get("wgNodeProperties", [])

    endpoints: List[Tuple[str, int]] = []
    for prop in sentinel_props:
        if prop.get("name") != "redis_sentinel_node_ready" or prop.get("value") != "true":
            continue
        node_id = prop.get("node_id")
        if not node_id:
            continue
        tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
        if tunnel_ip:
            endpoints.append((tunnel_ip, 26379))

    return sorted(set(endpoints))


def get_redis_master_endpoint(state_json: dict) -> Tuple[Tuple[str, int] | None, str | None]:
    """Resolve Redis master via Sentinel."""
    sentinel_endpoints = get_sentinel_connection_info(state_json)
    if not sentinel_endpoints:
        return None, "No Redis Sentinel endpoints available"

    try:
        import redis
    except ImportError:
        return None, "redis-py library not installed"

    last_error: str | None = None
    for host, port in sentinel_endpoints:
        try:
            r = redis.Redis(
                host=host,
                port=port,
                decode_responses=True,
                socket_connect_timeout=2,
            )
            res = r.execute_command("SENTINEL", "get-master-addr-by-name", "redis-master")
            if isinstance(res, (list, tuple)) and len(res) >= 2:
                return (res[0], int(res[1])), None
        except Exception as e:
            last_error = f"Sentinel {host}:{port} error: {e}"

    return None, last_error or "Failed to resolve Redis master via Sentinel"


def ensure_route_in_redis(state_json: dict) -> Tuple[bool, str | None]:
    """Create or update the OpenResty route in Redis Cluster.

    Targets are derived from Swarm state:
    - For each node in the test-app cluster (clusterNodes),
      we find its WireGuard tunnel IP via wgNodeProperties.
    - Each such IP becomes a backend URL http://<ip>:APP_PORT.
    """
    master_endpoint, err = get_redis_master_endpoint(state_json)
    if not master_endpoint:
        msg = err or "No Redis master endpoint available"
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
    except ImportError:
        return False, "redis-py library not installed"

    # A few retries in case Sentinel/Redis is still converging or there are
    # short-lived connectivity issues.
    max_retries = 20
    retry_delay_sec = 5
    last_error: str | None = None

    for attempt in range(1, max_retries + 1):
        try:
            print(
                f"[*] Attempt {attempt}/{max_retries} to set route {ROUTE_KEY} "
                f"in Redis via master={master_endpoint}",
                file=sys.stderr,
            )
            host, port = master_endpoint
            r = redis.Redis(
                host=host,
                port=port,
                decode_responses=True,
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
                f"in Redis on attempt {attempt}",
                file=sys.stderr,
            )
            return True, None
        except Exception as e:
            last_error = f"Failed to write route to Redis on attempt {attempt}: {e}"
            print(f"[!] {last_error}", file=sys.stderr)

            if attempt < max_retries:
                time.sleep(retry_delay_sec)

    # All attempts failed
    return False, last_error or "Failed to write route to Redis after retries"


def delete_route_from_redis(state_json: dict) -> Tuple[bool, str | None]:
    """Delete the OpenResty route from Redis Cluster."""
    master_endpoint, err = get_redis_master_endpoint(state_json)
    if not master_endpoint:
        return False, err or "No Redis master endpoint available"

    try:
        import redis
    except ImportError:
        return False, "redis-py library not installed"

    try:
        host, port = master_endpoint
        r = redis.Redis(
            host=host,
            port=port,
            decode_responses=True,
            socket_connect_timeout=5,
        )
        r.delete(ROUTE_KEY)
        print(f"[*] Deleted route {ROUTE_KEY} from Redis", file=sys.stderr)
        return True, None
    except Exception as e:
        error_msg = f"Failed to delete route from Redis: {str(e)}"
        print(f"[!] {error_msg}", file=sys.stderr)
        return False, error_msg


@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Wait until Redis is reachable (for leader); non-leaders are no-op."""
    local_state = input_data.local_state or {}
    state_json = input_data.state or {}

    if not isinstance(state_json, dict):
        return PluginOutput(
            status="error",
            error_message="Invalid state format in init",
            local_state=local_state,
        )

    local_node_id = input_data.local_node_id

    # Only leader needs to wait for Redis; other nodes can treat init as no-op.
    if not is_local_node_leader(local_node_id, state_json):
        return PluginOutput(status="completed", local_state=local_state)

    master_endpoint, err = get_redis_master_endpoint(state_json)
    if not master_endpoint:
        msg = err or "No Redis master endpoint available (init)"
        print(f"[!] {msg}", file=sys.stderr)
        return PluginOutput(
            status="postponed",
            error_message=msg,
            local_state=local_state,
        )

    # Optionally verify that Redis cluster is reachable from at least one endpoint.
    try:
        import redis
    except ImportError:
        msg = "redis-py library not installed (init)"
        print(f"[!] {msg}", file=sys.stderr)
        return PluginOutput(
            status="postponed",
            error_message=msg,
            local_state=local_state,
        )

    max_retries = 3
    retry_delay_sec = 5
    last_error: str | None = None

    for attempt in range(1, max_retries + 1):
        try:
            print(
                f"[*] init: attempt {attempt}/{max_retries} to ping Redis master "
                f"via {master_endpoint}",
                file=sys.stderr,
            )
            host, port = master_endpoint
            r = redis.Redis(
                host=host,
                port=port,
                decode_responses=True,
                socket_connect_timeout=5,
            )
            r.ping()

            print(
                f"[*] init: Redis master is reachable on attempt {attempt}",
                file=sys.stderr,
            )
            return PluginOutput(status="completed", local_state=local_state)
        except Exception as e:
            last_error = f"init: failed to ping Redis master on attempt {attempt}: {e}"
            print(f"[!] {last_error}", file=sys.stderr)
            if attempt < max_retries:
                time.sleep(retry_delay_sec)

    # If we reach here, Redis is still not reachable — postpone init.
    return PluginOutput(
        status="postponed",
        error_message=last_error or "init: Redis master is not reachable",
        local_state=local_state,
    )


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

    try:
        import redis
    except ImportError:
        # If library is missing, health is postponed rather than fatal
        return PluginOutput(
            status="postponed",
            error_message="redis-py library not installed",
            local_state=local_state,
        )

    master_endpoint, err = get_redis_master_endpoint(state_json)
    if not master_endpoint:
        return PluginOutput(
            status="postponed",
            error_message=err or "No Redis master endpoint available",
            local_state=local_state,
        )

    try:
        host, port = master_endpoint
        r = redis.Redis(
            host=host,
            port=port,
            decode_responses=True,
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
