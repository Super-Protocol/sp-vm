#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import hashlib
import time
import re
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
RKE2_VERSION = os.environ.get("RKE2_VERSION", "v1.32.8+rke2r1")
RKE2_TOKEN = os.environ.get("RKE2_TOKEN", "DefaultRke2ClusterToken12345")
RKE2_CONFIG_DIR = Path("/etc/rancher/rke2")
RKE2_CONFIG_FILE = RKE2_CONFIG_DIR / "config.yaml"
RKE2_SERVER_PORT = 9345
KUBECTL_BIN = os.environ.get("RKE2_KUBECTL", "/var/lib/rancher/rke2/bin/kubectl")
RKE2_KUBECONFIG = Path("/etc/rancher/rke2/rke2.yaml")

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def hash_node_id(node_id: str) -> str:
    """Create hex MD5 hash of node ID for k8s node name compatibility."""
    return hashlib.md5(node_id.encode()).hexdigest()


def compute_install_hash(state_json: dict, version: str, token: str) -> str:
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

    payload = "|".join(node_ids) + "|" + "|".join(wg_addresses) + "|" + str(RKE2_SERVER_PORT) + "|" + token + "|" + version
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


def is_bootstrap_done(rke2_props: list) -> bool:
    """Check if bootstrap is already done by any node."""
    for prop in rke2_props:
        if prop.get("name") == "k8s_bootstrap_done" and prop.get("value") == "true":
            return True
    return False


def get_leader_node(state_json: dict) -> str | None:
    """Get leader node ID from cluster info."""
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def is_rke2_available() -> bool:
    """Check if RKE2 binaries are available."""
    return shutil.which("rke2") is not None


def ensure_kernel_settings():
    """Configure kernel settings for RKE2."""
    errors = []
    try:
        result = subprocess.run(["modprobe", "br_netfilter"], capture_output=True, text=True)
        if result.returncode != 0:
            errors.append(f'Failed to load br_netfilter: {result.stderr}')
    except Exception as e:
        errors.append(f'Failed to load br_netfilter: {str(e)}')

    sysctls = [
        ("net.bridge.bridge-nf-call-iptables", "1"),
        ("net.bridge.bridge-nf-call-ip6tables", "1"),
        ("net.ipv4.ip_forward", "1"),
        ("net.ipv4.conf.all.rp_filter", "2"),
        ("net.ipv4.conf.default.rp_filter", "2"),
    ]

    for k, v in sysctls:
        try:
            result = subprocess.run(["sysctl", "-w", f"{k}={v}"], capture_output=True, text=True)
            if result.returncode != 0:
                errors.append(f'Failed to set {k}={v}: {result.stderr}')
        except Exception as e:
            errors.append(f'Failed to set {k}={v}: {str(e)}')

    if errors:
        raise Exception('; '.join(errors))


def install_rke2():
    """Install RKE2 using the official installation script."""
    try:
        env = os.environ.copy()
        env["INSTALL_RKE2_VERSION"] = RKE2_VERSION
        result = subprocess.run(
            ["/bin/sh", "-c", "curl -sfL https://get.rke2.io | sh -"],
            env=env,
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f'Installation script failed: {result.stderr}')
    except Exception as e:
        print(f"[!] Failed to install RKE2: {e}", file=sys.stderr)
        raise


def write_rke2_config(local_node_id: str, local_tunnel_ip: str, is_bootstrap: bool, leader_tunnel_ip: str | None, all_tunnel_ips: list):
    """Write RKE2 configuration file."""
    RKE2_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    local_hashed_id = hash_node_id(local_node_id)

    cfg_lines = [
        f"token: {RKE2_TOKEN}",
        f"node-ip: {local_tunnel_ip}",
        f"node-name: {local_hashed_id}",
        "cni: cilium",
        "disable-kube-proxy: true"
    ]

    # Add TLS SANs for all tunnel IPs
    if all_tunnel_ips:
        cfg_lines.append("tls-san:")
        for ip in sorted(set(all_tunnel_ips)):
            cfg_lines.append(f"  - {ip}")

    # Add server parameter for non-bootstrap nodes
    if not is_bootstrap and leader_tunnel_ip:
        cfg_lines.append(f"server: https://{leader_tunnel_ip}:{RKE2_SERVER_PORT}")

    RKE2_CONFIG_FILE.write_text("\n".join(cfg_lines) + "\n")


def write_cilium_cni_config():
    """Write Cilium CNI configuration for WireGuard."""
    manifests_dir = Path("/var/lib/rancher/rke2/server/manifests")
    manifests_dir.mkdir(parents=True, exist_ok=True)

    cilium_config = """---
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    # Use VXLAN overlay and route via WireGuard interface
    routingMode: tunnel
    tunnelProtocol: vxlan
    autoDetectDevices: "interface=wg0"
    mtu: 1370
    kubeProxyReplacement: strict
"""

    (manifests_dir / "rke2-cilium-config.yaml").write_text(cilium_config)


def write_ingress_nginx_config():
    """Write ingress-nginx configuration for NodePort."""
    manifests_dir = Path("/var/lib/rancher/rke2/server/manifests")
    manifests_dir.mkdir(parents=True, exist_ok=True)

    ingress_config = """---
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-ingress-nginx
  namespace: kube-system
spec:
  failurePolicy: reinstall
  valuesContent: |-
    controller:
      kind: DaemonSet
      hostNetwork: false
      dnsPolicy: ClusterFirst
      hostPort:
        enabled: false
      publishService:
        enabled: true
      service:
        enabled: true
        type: NodePort
        nodePorts:
          http: 30080
          https: 30443
        externalTrafficPolicy: Local
      extraArgs: {}
      config: {}
"""

    (manifests_dir / "rke2-ingress-nginx-config.yaml").write_text(ingress_config)


def wait_for_api_ready(timeout_sec: int = 600) -> bool:
    """Wait for RKE2 API server to become ready."""
    if not RKE2_KUBECONFIG.exists():
        print("[!] Kubeconfig not found, waiting for API ready", file=sys.stderr)
        return False

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    start_time = time.time()
    last_error = None

    while time.time() - start_time < timeout_sec:
        try:
            result = subprocess.run(
                [KUBECTL_BIN, "get", "--raw", "/healthz"],
                env=env,
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0 and result.stdout.strip() == "ok":
                return True

            last_error = f"API returned: {result.stdout.strip()}"
        except subprocess.TimeoutExpired:
            last_error = "API health check timed out"
        except Exception as e:
            last_error = f"API health check error: {str(e)}"

        time.sleep(3)

    print(f"[!] API did not become ready within {timeout_sec}s. Last error: {last_error}", file=sys.stderr)
    return False


def is_rke2_running() -> tuple[bool, str | None]:
    """Check if RKE2 server is running.
    Returns (is_running, error_message)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "rke2-server"],
            capture_output=True,
            text=True
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def check_node_ready(local_node_id: str) -> tuple[bool, str | None]:
    """Check if local node is Ready in Kubernetes.
    Returns (is_ready, error_message)
    """
    if not RKE2_KUBECONFIG.exists():
        return False, "Kubeconfig not found"

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    node_name = hash_node_id(local_node_id)

    try:
        result = subprocess.run(
            [KUBECTL_BIN, "get", "node", node_name, "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode != 0:
            return False, f'Failed to get node status: {result.stderr}'
        is_ready = result.stdout.strip() == "True"
        return is_ready, None if is_ready else f'Node status: {result.stdout.strip()}'
    except Exception as e:
        return False, f'Failed to check node readiness: {str(e)}'


def get_kubeconfig_with_wireguard_server(local_tunnel_ip: str) -> str | None:
    """Read kubeconfig and replace server URL with WireGuard tunnel IP.
    Returns modified kubeconfig as string or None on error.
    """
    if not RKE2_KUBECONFIG.exists():
        return None

    try:
        kubeconfig_content = RKE2_KUBECONFIG.read_text()

        # Replace server URL with WireGuard tunnel IP
        # Match server: https://127.0.0.1:6443 or server: https://<any-ip>:6443
        modified_kubeconfig = re.sub(
            r'(\s+server:\s+https://)([^:]+)(:\d+)',
            rf'\g<1>{local_tunnel_ip}\g<3>',
            kubeconfig_content
        )

        return modified_kubeconfig
    except Exception as e:
        print(f"[!] Failed to read/modify kubeconfig: {e}", file=sys.stderr)
        return None


def get_k8s_nodes() -> list[str]:
    """Get list of all node names in the Kubernetes cluster.
    Returns empty list on error (logs to stderr).
    """
    if not RKE2_KUBECONFIG.exists():
        print("[!] Kubeconfig not found", file=sys.stderr)
        return []

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    # Retry with exponential backoff
    last_error = None
    for attempt in range(3):
        try:
            result = subprocess.run(
                [KUBECTL_BIN, "get", "nodes", "-o", "jsonpath={.items[*].metadata.name}", "--request-timeout=30s"],
                env=env,
                capture_output=True,
                text=True,
                timeout=45
            )
            if result.returncode == 0:
                nodes = result.stdout.strip().split()
                return [n for n in nodes if n]  # Filter empty strings

            # On error, wait before retry
            last_error = f"kubectl failed: {result.stderr}"
            if attempt < 2:
                time.sleep(2 ** attempt)
        except subprocess.TimeoutExpired as e:
            last_error = f"kubectl timed out: {str(e)}"
            if attempt < 2:
                time.sleep(2 ** attempt)
        except Exception as e:
            last_error = f"kubectl error: {str(e)}"
            if attempt < 2:
                time.sleep(2 ** attempt)

    print(f"[!] Failed to get k8s nodes after 3 attempts: {last_error}", file=sys.stderr)
    return []


def cordon_node(node_name: str) -> bool:
    """Cordon a node to prevent new pods from being scheduled."""
    if not RKE2_KUBECONFIG.exists():
        return False

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    try:
        result = subprocess.run(
            [KUBECTL_BIN, "cordon", node_name, "--request-timeout=30s"],
            env=env,
            capture_output=True,
            text=True,
            timeout=45
        )
        return result.returncode == 0
    except Exception as e:
        print(f"[!] Cordon failed: {e}", file=sys.stderr)
        return False


def drain_node(node_name: str) -> bool:
    """Drain a node to evict all pods."""
    if not RKE2_KUBECONFIG.exists():
        return False

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    try:
        result = subprocess.run(
            [
                KUBECTL_BIN, "drain", node_name,
                "--ignore-daemonsets",
                "--delete-emptydir-data",
                "--force",
                "--grace-period=30",
                "--timeout=60s",
                "--request-timeout=60s"
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=90
        )
        if result.returncode != 0:
            print(f"[!] Drain stderr: {result.stderr}", file=sys.stderr)
        return result.returncode == 0
    except Exception as e:
        print(f"[!] Drain exception: {e}", file=sys.stderr)
        return False


def delete_node(node_name: str) -> bool:
    """Delete a node from the Kubernetes cluster."""
    if not RKE2_KUBECONFIG.exists():
        return False

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    try:
        result = subprocess.run(
            [KUBECTL_BIN, "delete", "node", node_name, "--request-timeout=30s"],
            env=env,
            capture_output=True,
            text=True,
            timeout=45
        )
        if result.returncode != 0:
            print(f"[!] Delete node stderr: {result.stderr}", file=sys.stderr)
        return result.returncode == 0
    except Exception as e:
        print(f"[!] Delete node exception: {e}", file=sys.stderr)
        return False


def remove_stale_nodes(cluster_nodes: list, local_state: dict) -> tuple[bool, list[str]]:
    """
    Remove nodes that are no longer in the cluster state.
    Returns (success, list of removed node names).
    """
    # Get current node IDs from state
    current_node_ids = {node.get("node_id") for node in cluster_nodes}

    # Get previously seen node IDs
    previous_node_ids = set(local_state.get("known_node_ids", []))

    # Find nodes that disappeared
    disappeared_node_ids = previous_node_ids - current_node_ids

    if not disappeared_node_ids:
        return True, []

    print(f"[*] Detected {len(disappeared_node_ids)} disappeared node(s)", file=sys.stderr)

    # Get all nodes in k8s cluster
    k8s_nodes = get_k8s_nodes()

    # If we can't get k8s nodes, the API might be stuck
    if not k8s_nodes and previous_node_ids:
        print(f"[!] Cannot retrieve k8s nodes - API server may be unhealthy", file=sys.stderr)
        # Return success but with empty removed list to avoid blocking
        # The health check will eventually detect the API issue
        return True, []

    removed_nodes = []
    for node_id in disappeared_node_ids:
        node_name = hash_node_id(node_id)

        # Check if this node exists in k8s
        if node_name not in k8s_nodes:
            print(f"[*] Node {node_name} already removed from k8s", file=sys.stderr)
            removed_nodes.append(node_name)
            continue

        print(f"[*] Removing stale node {node_name} (node_id: {node_id})", file=sys.stderr)

        # Cordon the node (best effort)
        if cordon_node(node_name):
            print(f"[*] Cordoned node {node_name}", file=sys.stderr)
        else:
            print(f"[!] Failed to cordon node {node_name}, continuing...", file=sys.stderr)

        # Drain the node (best effort)
        if drain_node(node_name):
            print(f"[*] Drained node {node_name}", file=sys.stderr)
        else:
            print(f"[!] Failed to drain node {node_name}, continuing...", file=sys.stderr)

        # Delete the node - this is the critical operation
        if delete_node(node_name):
            print(f"[*] Deleted node {node_name}", file=sys.stderr)
            removed_nodes.append(node_name)
        else:
            print(f"[!] Failed to delete node {node_name}, will retry on next reconcile", file=sys.stderr)
            # Don't return error - allow other nodes to be processed

    return True, removed_nodes


# Plugin commands

@plugin.command('init')
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize RKE2: install packages and configure kernel."""
    try:
        # Install RKE2 if not present
        if not is_rke2_available():
            install_rke2()

        # Configure kernel settings
        ensure_kernel_settings()

        return PluginOutput(status='completed', local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=str(e), local_state=input_data.local_state)


@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply RKE2 configuration and start the cluster."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='error', error_message='Invalid state format', local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    rke2_props = state_json.get("rke2NodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])
    cluster = state_json.get("cluster", {})

    # Check if all nodes have WireGuard configured
    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        return PluginOutput(
            status='postponed',
            error_message='Waiting for WireGuard to be configured on all nodes',
            local_state=local_state
        )

    # Determine if this is bootstrap node (leader_node from cluster)
    leader_node_id = get_leader_node(state_json)
    is_bootstrap = (leader_node_id == local_node_id)
    bootstrap_done = is_bootstrap_done(rke2_props)

    # For non-bootstrap nodes: wait for bootstrap to complete
    if not is_bootstrap and not bootstrap_done:
        return PluginOutput(
            status='postponed',
            error_message=f'Waiting for bootstrap node {leader_node_id} to complete initialization',
            local_state=local_state
        )

    # For non-bootstrap nodes: also wait for leader's k8s_node_ready flag
    if not is_bootstrap:
        leader_ready = False
        for prop in rke2_props:
            node_id = prop.get("node_id")
            if node_id == leader_node_id and prop.get("name") == "k8s_node_ready" and prop.get("value") == "true":
                leader_ready = True
                break

        if not leader_ready:
            return PluginOutput(
                status='postponed',
                error_message=f'Waiting for bootstrap node {leader_node_id} to become ready',
                local_state=local_state
            )

    # Get local tunnel IP
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(
            status='error',
            error_message='Local node has no WireGuard tunnel IP',
            local_state=local_state
        )

    # Get leader tunnel IP (for non-bootstrap nodes)
    leader_tunnel_ip = None
    if not is_bootstrap and leader_node_id:
        leader_tunnel_ip = get_node_tunnel_ip(leader_node_id, wg_props)
        if not leader_tunnel_ip:
            return PluginOutput(
                status='postponed',
                error_message='Bootstrap node has no WireGuard tunnel IP yet',
                local_state=local_state
            )

    # Collect all tunnel IPs for TLS SANs
    all_tunnel_ips = []
    for node in cluster_nodes:
        tunnel_ip = get_node_tunnel_ip(node.get("node_id"), wg_props)
        if tunnel_ip:
            all_tunnel_ips.append(tunnel_ip)

    # Compute install hash to detect config changes
    install_hash = compute_install_hash(state_json, RKE2_VERSION, RKE2_TOKEN)

    # Track known node IDs for stale node detection
    current_node_ids = [node.get("node_id") for node in cluster_nodes]

    # If this is the leader node and API is ready, remove stale nodes
    if is_bootstrap and local_state.get("api_ready"):
        print(f"[*] Leader node checking for stale nodes to remove", file=sys.stderr)
        success, removed_nodes = remove_stale_nodes(cluster_nodes, local_state)
        if not success:
            print(f"[!] Failed to remove stale nodes from cluster", file=sys.stderr)
            return PluginOutput(
                status='postponed',
                error_message='Failed to remove stale nodes from cluster',
                local_state={**local_state, "known_node_ids": current_node_ids}
            )
        if removed_nodes:
            print(f"[*] Apply: Successfully removed {len(removed_nodes)} stale node(s): {', '.join(removed_nodes)}", file=sys.stderr)

    # Check if we need to reconfigure
    prev_install_hash = local_state.get("install_hash")
    if prev_install_hash == install_hash and local_state.get("api_ready"):
        # No changes, skip reconfiguration but update known nodes
        return PluginOutput(
            status='completed',
            local_state={**local_state, "known_node_ids": current_node_ids}
        )

    # Write RKE2 configuration
    try:
        write_rke2_config(local_node_id, local_tunnel_ip, is_bootstrap, leader_tunnel_ip, all_tunnel_ips)
        write_cilium_cni_config()
        write_ingress_nginx_config()
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to write config: {str(e)}', local_state=local_state)

    # Start RKE2 server
    try:
        result = subprocess.run(["systemctl", "enable", "rke2-server"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to enable RKE2: {result.stderr}', local_state=local_state)

        result = subprocess.run(["systemctl", "start", "rke2-server"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to start RKE2: {result.stderr}', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to start RKE2: {str(e)}', local_state=local_state)

    # Wait for API to become ready
    api_ready = wait_for_api_ready(timeout_sec=600)

    if not api_ready:
        return PluginOutput(
            status='postponed',
            error_message='RKE2 API did not become ready within timeout',
            local_state={**local_state, "install_hash": install_hash, "api_ready": False}
        )

    # Update local state
    new_local_state = {
        **local_state,
        "install_hash": install_hash,
        "api_ready": api_ready,
        "role": "server",
        "is_bootstrap": is_bootstrap,
        "known_node_ids": current_node_ids
    }

    # Prepare node properties to publish
    node_properties = {}
    local_hashed_id = hash_node_id(local_node_id)

    # Set k8s_node_id
    node_properties["k8s_node_id"] = local_hashed_id

    # Set k8s_node_ready if API is ready
    if api_ready:
        node_properties["k8s_node_ready"] = "true"

    # Set k8s_bootstrap_done if this is bootstrap node and it's not set yet
    if is_bootstrap and not bootstrap_done:
        node_properties["k8s_bootstrap_done"] = "true"

    # Generate and publish kubeconfig with WireGuard tunnel IP as server address
    kubeconfig = get_kubeconfig_with_wireguard_server(local_tunnel_ip)
    if kubeconfig:
        node_properties["k8s_kubeconfig"] = kubeconfig
    else:
        print("[!] Failed to generate kubeconfig, skipping k8s_kubeconfig property", file=sys.stderr)

    return PluginOutput(
        status='completed',
        node_properties=node_properties,
        local_state=new_local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check RKE2 health."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Check if RKE2 is running
    rke2_running, rke2_error = is_rke2_running()
    if not rke2_running:
        if rke2_error and 'Failed to' in rke2_error:
            # Real error checking status
            return PluginOutput(status='error', error_message=rke2_error, local_state=local_state)
        else:
            # Service not running yet
            return PluginOutput(status='postponed', error_message=rke2_error or 'RKE2 service is not running', local_state=local_state)

    # Check API health
    if not RKE2_KUBECONFIG.exists():
        return PluginOutput(status='postponed', error_message='Kubeconfig not found', local_state=local_state)

    env = os.environ.copy()
    env["KUBECONFIG"] = str(RKE2_KUBECONFIG)

    try:
        result = subprocess.run(
            [KUBECTL_BIN, "get", "--raw", "/healthz"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0 or result.stdout.strip() != "ok":
            return PluginOutput(status='postponed', error_message='API server is not healthy', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='postponed', error_message=f'Failed to check API: {e}', local_state=local_state)

    # Check node readiness
    node_ready, node_error = check_node_ready(local_node_id)
    if not node_ready:
        if node_error and 'Failed to' in node_error:
            # Real error, not just not ready yet
            return PluginOutput(status='error', error_message=node_error, local_state=local_state)
        else:
            # Node not ready yet, postpone
            return PluginOutput(status='postponed', error_message=node_error or 'Node is not ready', local_state=local_state)

    # If this is the leader node, check for and remove stale nodes
    if isinstance(state_json, dict):
        leader_node_id = get_leader_node(state_json)
        is_leader = (leader_node_id == local_node_id)

        if is_leader:
            cluster_nodes = state_json.get("clusterNodes", [])
            current_node_ids = [node.get("node_id") for node in cluster_nodes]

            success, removed_nodes = remove_stale_nodes(cluster_nodes, local_state)
            if not success:
                return PluginOutput(
                    status='postponed',
                    error_message='Failed to remove stale nodes from cluster',
                    local_state={**local_state, "known_node_ids": current_node_ids}
                )
            if removed_nodes:
                print(f"[*] Health check: Successfully removed {len(removed_nodes)} stale node(s)", file=sys.stderr)

            # Update known nodes in local state
            local_state = {**local_state, "known_node_ids": current_node_ids}

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('finalize')
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize before node removal (graceful shutdown)."""
    local_state = input_data.local_state or {}

    # TODO: Implement graceful node drain if needed
    # This could involve:
    # - Cordoning the node
    # - Draining pods
    # - Waiting for pod evacuation

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy RKE2 installation and clean up."""
    try:
        # Stop and disable RKE2
        subprocess.run(["systemctl", "stop", "rke2-server"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "rke2-server"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Run uninstall script if it exists
        if Path("/usr/local/bin/rke2-uninstall.sh").exists():
            subprocess.run(["/usr/local/bin/rke2-uninstall.sh"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Remove config directory
        if RKE2_CONFIG_DIR.exists():
            shutil.rmtree(RKE2_CONFIG_DIR, ignore_errors=True)

        # Request deletion of node properties
        node_properties = {
            "k8s_node_id": None,
            "k8s_node_ready": None,
            "k8s_bootstrap_done": None,
            "k8s_kubeconfig": None,
        }

        return PluginOutput(
            status='completed',
            node_properties=node_properties,
            local_state={}
        )
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to destroy RKE2: {e}', local_state={})


if __name__ == "__main__":
    plugin.run()
