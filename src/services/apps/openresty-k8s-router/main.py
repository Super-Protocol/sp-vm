#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

KUBECTL_BIN = "/var/lib/rancher/rke2/bin/kubectl"
ROUTE_DOMAIN_SUFFIX = ".k8s.oresty.superprotocol.io"
REDIS_PORT = 6379

plugin = ProvisionPlugin()


def get_node_tunnel_ip(node_id: str, wg_props: List[Dict[str, Any]]) -> Optional[str]:
    """Get WireGuard tunnel IP for a node."""
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def get_redis_tunnel_ips(state_json: Dict[str, Any]) -> List[str]:
    """Get tunnel IPs of all ready Redis nodes from state."""
    redis_node_props = state_json.get("redisNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    redis_hosts: List[str] = []
    for prop in redis_node_props:
        if prop.get("name") == "redis_node_ready" and prop.get("value") == "true":
            node_id = prop.get("node_id")
            tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
            if tunnel_ip:
                redis_hosts.append(tunnel_ip)

    # deduplicate and sort for stability
    return sorted(set(redis_hosts))


def get_rke2_kubeconfig(state_json: Dict[str, Any]) -> Optional[str]:
    """Extract kubeconfig (with WireGuard server address) from rke2NodeProperties."""
    props = state_json.get("rke2NodeProperties") or []
    if not isinstance(props, list):
        return None

    # Prefer kubeconfig from leader node if available
    leader_node_id = None
    rke2_cluster = state_json.get("rke2Cluster")
    if isinstance(rke2_cluster, dict):
        leader_node_id = rke2_cluster.get("leader_node")

    best_value: Optional[str] = None
    for p in props:
        if p.get("name") != "k8s_kubeconfig":
            continue
        val = p.get("value")
        if not isinstance(val, str) or not val.strip():
            continue
        if leader_node_id and p.get("node_id") == leader_node_id:
            return val
        if best_value is None:
            best_value = val

    return best_value


def write_temp_kubeconfig(content: str) -> Path:
    """Write kubeconfig content to a temporary file and return its path."""
    tmp_dir = Path("/run/openresty-k8s-router")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_file = tempfile.NamedTemporaryFile(
        dir=str(tmp_dir),
        prefix="kubeconfig-",
        suffix=".yaml",
        delete=False,
    )
    path = Path(tmp_file.name)
    tmp_file.write(content.encode("utf-8"))
    tmp_file.close()
    return path


def list_ingress_hosts(kubeconfig: str) -> Tuple[List[str], Optional[str]]:
    """List all Ingress hosts from Kubernetes using provided kubeconfig content.
    Returns (hosts, error_message). On success error_message is None.
    """
    path = write_temp_kubeconfig(kubeconfig)
    env = os.environ.copy()
    env["KUBECONFIG"] = str(path)

    try:
        result = subprocess.run(
            [KUBECTL_BIN, "get", "ingress", "--all-namespaces", "-o", "json"],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            return [], f"kubectl error: {result.stderr or result.stdout}"

        data = json.loads(result.stdout or "{}")
        items = data.get("items") or []
        hosts: List[str] = []

        for item in items:
            spec = item.get("spec") or {}
            rules = spec.get("rules") or []
            for rule in rules:
                host = rule.get("host")
                if isinstance(host, str) and host.endswith(ROUTE_DOMAIN_SUFFIX):
                    hosts.append(host)

        # deduplicate
        return sorted(set(hosts)), None
    except Exception as e:
        return [], str(e)
    finally:
        try:
            path.unlink(missing_ok=True)
        except Exception:
            pass


def get_rke2_ingress_backends(state_json: Dict[str, Any]) -> List[str]:
    """Build backend URLs (http://<wg-ip>:30080) for all RKE2 nodes."""
    rke2_nodes = state_json.get("rke2ClusterNodes") or []
    wg_props = state_json.get("wgNodeProperties") or []
    backends: List[str] = []

    for node in rke2_nodes:
        node_id = node.get("node_id")
        if not node_id:
            continue
        ip = get_node_tunnel_ip(node_id, wg_props)
        if not ip:
            continue
        backends.append(f"http://{ip}:30080")

    return sorted(set(backends))


def write_routes_to_redis(
    redis_hosts: List[str],
    routes: Dict[str, Dict[str, Any]],
) -> Tuple[bool, Optional[str]]:
    """Write route definitions into Redis using redis-cli.
    routes: host -> route_dict
    Returns (success, error_message)
    """
    if not redis_hosts:
        return False, "No Redis hosts available"

    last_error: Optional[str] = None

    for host, route in routes.items():
        key = f"routes:{host}"
        value = json.dumps(route, separators=(",", ":"))

        # Try each Redis host until one succeeds
        success_for_key = False
        for rh in redis_hosts:
            try:
                proc = subprocess.run(
                    ["redis-cli", "-h", rh, "-p", str(REDIS_PORT), "-x", "SET", key],
                    input=value,
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                if proc.returncode == 0:
                    success_for_key = True
                    break
                else:
                    last_error = proc.stderr or proc.stdout or f"redis-cli exited with {proc.returncode}"
            except Exception as e:
                last_error = str(e)

        if not success_for_key:
            return False, f"Failed to write route for {host}: {last_error or 'unknown error'}"

    return True, None


@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    # Nothing to initialize; everything is done in apply based on state
    return PluginOutput(status="completed", local_state=input_data.local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    if not isinstance(state_json, dict):
        return PluginOutput(
            status="error",
            error_message="Invalid state format",
            local_state=local_state,
        )

    # Discover Redis hosts
    redis_hosts = get_redis_tunnel_ips(state_json)
    if not redis_hosts:
        return PluginOutput(
            status="postponed",
            error_message="Waiting for Redis nodes to become ready",
            local_state=local_state,
        )

    # Get kubeconfig for this RKE2 cluster
    kubeconfig = get_rke2_kubeconfig(state_json)
    if not kubeconfig:
        return PluginOutput(
            status="postponed",
            error_message="Waiting for RKE2 kubeconfig (k8s_kubeconfig) to become available",
            local_state=local_state,
        )

    # Build backends from RKE2 nodes (ingress-nginx NodePort 30080)
    backends = get_rke2_ingress_backends(state_json)
    if not backends:
        return PluginOutput(
            status="postponed",
            error_message="No RKE2 nodes with WireGuard tunnel IPs available for ingress backends",
            local_state=local_state,
        )

    # List ingress hosts from Kubernetes
    hosts, err = list_ingress_hosts(kubeconfig)
    if err:
        return PluginOutput(
            status="postponed",
            error_message=f"Failed to list Kubernetes ingresses: {err}",
            local_state=local_state,
        )

    if not hosts:
        # No matching ingresses yet; nothing to route
        return PluginOutput(status="completed", local_state=local_state)

    # Build route definitions for each host
    routes: Dict[str, Dict[str, Any]] = {}
    targets = [{"url": url, "weight": 1} for url in backends]

    for host in hosts:
        routes[host] = {
            "policy": "rr",
            "preserve_host": True,
            "targets": targets,
        }

    ok, err = write_routes_to_redis(redis_hosts, routes)
    if not ok:
        return PluginOutput(
            status="postponed",
            error_message=err or "Failed to write routes to Redis",
            local_state=local_state,
        )

    # Optionally, store last known hosts/backends to detect changes later
    new_local_state = {
        **local_state,
        "last_hosts": hosts,
        "last_backends": backends,
    }

    return PluginOutput(status="completed", local_state=new_local_state)


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    # For now, consider router healthy if last apply succeeded (i.e., no error stored in state)
    # More advanced checks (e.g. probing Redis) can be added later.
    return PluginOutput(status="completed", local_state=input_data.local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    # Nothing special to do before node removal for this stateless router
    return PluginOutput(status="completed", local_state=input_data.local_state or {})


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    # We deliberately do not mass-delete routes from Redis here, as they may be shared
    # or quickly recreated by another instance. Just clear local state.
    return PluginOutput(status="completed", local_state={})


if __name__ == "__main__":
    plugin.run()
