#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import hashlib
import time
import json
import requests
from pathlib import Path
from typing import Optional

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
KNOT_VERSION = os.environ.get("KNOT_VERSION", "3.5.1")
KNOT_CONFIG_DIR = Path("/etc/knot")
KNOT_CONFIG_FILE = KNOT_CONFIG_DIR / "knot.conf"
KNOT_ZONES_DIR = KNOT_CONFIG_DIR / "zones"
KNOT_DATA_DIR = Path("/var/lib/knot")
KNOT_CLI = "knotc"
KNOT_PORT = 53

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def get_node_tunnel_ip(node_id: str, wg_props: list) -> str | None:
    """Get WireGuard tunnel IP for a node."""
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def get_node_addr(node_id: str, node_addrs: list) -> str | None:
    """Get physical address for a node."""
    for node in node_addrs:
        if node.get("node_id") == node_id:
            return node.get("addr")
    return None


def check_all_nodes_have_wg(cluster_nodes: list, wg_props: list) -> bool:
    """Check if all cluster nodes have WireGuard tunnel IPs."""
    for node in cluster_nodes:
        node_id = node.get("node_id")
        if not get_node_tunnel_ip(node_id, wg_props):
            return False
    return True


def is_cluster_initialized(knot_props: list) -> bool:
    """Check if cluster is already initialized by any node."""
    for prop in knot_props:
        if prop.get("name") == "knot_cluster_initialized" and prop.get("value") == "true":
            return True
    return False


def check_all_nodes_knot_ready(cluster_nodes: list, knot_props: list, local_node_id: str = None) -> bool:
    """Check if all cluster nodes have Knot running and ready.

    Args:
        cluster_nodes: List of cluster nodes
        knot_props: List of knot node properties
        local_node_id: ID of local node (treated as ready if provided)
    """
    not_ready_nodes = []
    for node in cluster_nodes:
        node_id = node.get("node_id")

        # Treat local node as ready since we're about to mark it
        if local_node_id and node_id == local_node_id:
            continue

        node_ready = False
        for prop in knot_props:
            if (prop.get("node_id") == node_id and
                prop.get("name") == "knot_node_ready" and
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




def get_secret_from_swarmdb(state_json: dict, secret_id: str) -> str | None:
    """Get secret value from SwarmSecrets table."""
    secrets = state_json.get("swarmSecrets", [])
    for secret in secrets:
        if secret.get("id") == secret_id:
            return secret.get("value")
    return None


def is_knot_available() -> bool:
    """Check if Knot binaries are available."""
    return shutil.which("knotd") is not None


def generate_tsig_key() -> tuple[str, str] | None:
    """Generate TSIG key for DNS UPDATE authentication.

    Returns:
        (key_name, key_secret) tuple or None on failure
    """
    try:
        key_name = "swarm-update-key"

        # Generate TSIG key using keymgr or manually
        # Format: keymgr will generate hmac-sha256 key
        result = subprocess.run(
            ["dd", "if=/dev/urandom", "bs=32", "count=1"],
            capture_output=True,
            timeout=10
        )

        if result.returncode != 0:
            print(f"[!] Failed to generate random bytes", file=sys.stderr)
            return None

        # Base64 encode the key
        import base64
        key_secret = base64.b64encode(result.stdout).decode('ascii')

        print(f"[*] Generated TSIG key: {key_name}", file=sys.stderr)
        return (key_name, key_secret)

    except Exception as e:
        print(f"[!] Failed to generate TSIG key: {e}", file=sys.stderr)
        import traceback
        print(f"[!] Traceback: {traceback.format_exc()}", file=sys.stderr)
        return None


def run_cmd(cmd, err_msg):
    """Run command and raise exception on failure."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"{err_msg}: {result.stderr.strip()}")
    return result


def install_knot(version=KNOT_VERSION):
    """Install specific Knot DNS version from CZ.NIC upstream repo."""
    try:
        # Detect Ubuntu
        if not os.path.exists("/etc/os-release"):
            raise Exception("Cannot detect OS: /etc/os-release not found")

        with open("/etc/os-release", "r") as f:
            os_rel = f.read().lower()

        if "ubuntu" not in os_rel:
            raise Exception("Unsupported OS")

        # Clean old repos if present
        legacy_files = [
            "/etc/apt/sources.list.d/knot-latest.list",
            "/etc/apt/sources.list.d/knot.list",
        ]
        for path in legacy_files:
            if os.path.exists(path):
                try:
                    os.remove(path)
                    print(f"[*] Removed old repo: {path}", file=sys.stderr)
                except Exception as e:
                    print(f"[!] Failed to remove {path}: {e}", file=sys.stderr)

        # Base update
        run_cmd(["apt-get", "update"], "apt-get update failed")

        # Install required packages
        run_cmd(
            ["apt-get", "-y", "install",
             "apt-transport-https", "ca-certificates", "wget", "gnupg"],
            "Failed to install prerequisites"
        )

        # Add GPG key
        run_cmd(
            [
                "wget", "-O", "/usr/share/keyrings/cznic-labs-pkg.gpg",
                "https://pkg.labs.nic.cz/gpg"
            ],
            "Failed to download CZ.NIC GPG key"
        )

        # Add repository
        repo_line = (
            "deb [signed-by=/usr/share/keyrings/cznic-labs-pkg.gpg] "
            "https://pkg.labs.nic.cz/knot-dns noble main"
        )
        with open("/etc/apt/sources.list.d/cznic-labs-knot-dns.list", "w") as f:
            f.write(repo_line + "\n")

        print(f"[*] Added repo: {repo_line}", file=sys.stderr)

        # Add version pinning
        pref_file = "/etc/apt/preferences.d/knot"
        pref_content = f"""Package: knot knot-* libdnssec* libzscanner* libknot* python3-libknot*
Pin-Priority: 1001
Pin: version {version}*
"""
        with open(pref_file, "w") as f:
            f.write(pref_content)

        print(f"[*] Added pinning for Knot version {version}", file=sys.stderr)

        # Update with repo enabled
        run_cmd(["apt-get", "update"], "apt-get update failed after adding repo")

        # Install exact version
        run_cmd(
            ["apt-get", "-y", "install", f"knot={version}*"],
            f"Failed to install Knot DNS version {version}"
        )

        print(f"[*] Successfully installed Knot DNS version {version}", file=sys.stderr)

        # Show what was installed
        policy = run_cmd(["apt-cache", "policy", "knot"],
                         "apt-cache policy failed").stdout
        print("[*] Installed version info:\n" + policy, file=sys.stderr)

    except Exception as e:
        print(f"[!] Failed to install Knot DNS: {e}", file=sys.stderr)
        raise


def write_knot_config(
    local_node_id: str,
    local_tunnel_ip: str,
    cluster_nodes: list,
    wg_props: list,
    node_addrs: list,
    is_catalog_master: bool,
    tsig_key_name: str,
    tsig_key_secret: str,
    catalog_master_ip: str = None
):
    """Write Knot DNS configuration file with RFC 2136, TSIG, and catalog zones support.

    Args:
        local_node_id: ID of local node
        local_tunnel_ip: Local WireGuard tunnel IP
        cluster_nodes: List of all cluster nodes
        wg_props: WireGuard properties with tunnel IPs
        node_addrs: List of node address records from SwarmDB
        is_catalog_master: Whether this node is the catalog zone master
        tsig_key_name: TSIG key name for authentication
        tsig_key_secret: TSIG key secret (base64)
        catalog_master_ip: IP of catalog master (for non-master nodes)
    """
    KNOT_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    KNOT_ZONES_DIR.mkdir(parents=True, exist_ok=True)
    KNOT_DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Determine listen address for this node.
    # Upstream used 0.0.0.0@53, but in this VM dnsmasq already binds 10.0.3.1:53.
    # To avoid conflicts while still serving DNS on the node's primary address,
    # bind Knot only to the local node's address, falling back to its WireGuard IP.
    listen_ip = get_node_addr(local_node_id, node_addrs) or local_tunnel_ip

    # Build list of remote server IPs (all nodes except local)
    remote_ips = []
    for node in cluster_nodes:
        node_id = node.get("node_id")
        if node_id == local_node_id:
            continue
        tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
        if tunnel_ip:
            remote_ips.append(tunnel_ip)

    # Remote servers configuration for catalog zone members
    remote_section = ""
    if remote_ips:
        remote_lines = "\n".join([
            f"  - id: node_{i}\n    address: {ip}@{KNOT_PORT}\n    key: {tsig_key_name}"
            for i, ip in enumerate(remote_ips)
        ])
        remote_section = f"remote:\n{remote_lines}\n"

    # Catalog zone configuration
    catalog_zone_name = "swarm-catalog"
    catalog_config = ""

    if is_catalog_master:
        # Master node: catalog-generate
        catalog_config = f"""
# Catalog zone (master node)
template:
  - id: catalog
    storage: "{KNOT_ZONES_DIR}"
    semantic-checks: on
    catalog-role: generate
    catalog-zone: {catalog_zone_name}

  - id: default
    storage: "{KNOT_ZONES_DIR}"
    semantic-checks: on
    acl: [tsig_update_acl]

zone:
  - domain: {catalog_zone_name}
    storage: "{KNOT_ZONES_DIR}"
    file: "{catalog_zone_name}.zone"
"""
    else:
        # Member node: catalog-interpret
        catalog_config = f"""
# Catalog zone (member node)
template:
  - id: catalog
    storage: "{KNOT_ZONES_DIR}"
    semantic-checks: on
    catalog-role: interpret
    catalog-zone: {catalog_zone_name}

  - id: default
    storage: "{KNOT_ZONES_DIR}"
    semantic-checks: on
    acl: [tsig_update_acl]

zone:
  - domain: {catalog_zone_name}
    storage: "{KNOT_ZONES_DIR}"
    master: node_0
    acl: [notify_from_master]
"""

    cfg_content = f"""# Knot DNS Configuration with TSIG, RFC 2136, and Catalog Zones

server:
    listen: {listen_ip}@{KNOT_PORT}
    rundir: "/run/knot"
    user: knot:knot
    pidfile: "/run/knot/knot.pid"

log:
  - target: syslog
    any: info

database:
    storage: "{KNOT_DATA_DIR}"

key:
  - id: {tsig_key_name}
    algorithm: hmac-sha256
    secret: {tsig_key_secret}

{remote_section}
acl:
  - id: tsig_update_acl
    key: {tsig_key_name}
    action: update

  - id: notify_from_master
    key: {tsig_key_name}
    action: notify

{catalog_config}

# User zones will be added to catalog automatically
"""

    KNOT_CONFIG_FILE.write_text(cfg_content)
    print(f"[*] Wrote Knot config to {KNOT_CONFIG_FILE}", file=sys.stderr)
    print(f"[*] Role: {'CATALOG MASTER' if is_catalog_master else 'CATALOG MEMBER'}", file=sys.stderr)
    print(f"[*] TSIG key: {tsig_key_name}", file=sys.stderr)


def is_knot_running() -> tuple[bool, str | None]:
    """Check if Knot DNS server is running.
    Returns (is_running, error_message)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "knot"],
            capture_output=True,
            text=True
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def wait_for_knot_ready(timeout_sec: int = 30) -> bool:
    """Wait for Knot DNS server to become ready."""
    start_time = time.time()

    while time.time() - start_time < timeout_sec:
        try:
            result = subprocess.run(
                [KNOT_CLI, "status"],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                return True

        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass

        time.sleep(2)

    return False


def create_catalog_zone_file(catalog_zone_name: str = "swarm-catalog") -> bool:
    """Create initial catalog zone file for master node.

    Args:
        catalog_zone_name: Name of catalog zone

    Returns:
        True if created successfully, False otherwise
    """
    try:
        catalog_file = KNOT_ZONES_DIR / f"{catalog_zone_name}.zone"

        # Don't recreate if already exists
        if catalog_file.exists():
            print(f"[*] Catalog zone file already exists: {catalog_file}", file=sys.stderr)
            return True

        # Create minimal catalog zone file
        catalog_content = f"""$ORIGIN {catalog_zone_name}.
$TTL 3600

@   SOA ns1.{catalog_zone_name}. admin.{catalog_zone_name}. (
        1          ; serial
        3600       ; refresh
        1800       ; retry
        604800     ; expire
        86400 )    ; minimum

@   NS  ns1.{catalog_zone_name}.
ns1 A   127.0.0.1

; Member zones will be added automatically by catalog-role: generate
"""
        catalog_file.write_text(catalog_content)
        print(f"[*] Created catalog zone file: {catalog_file}", file=sys.stderr)

        # Set proper ownership
        subprocess.run(
            ["chown", "knot:knot", str(catalog_file)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        return True

    except Exception as e:
        print(f"[!] Failed to create catalog zone file: {e}", file=sys.stderr)
        return False


def create_zone_in_knot(zone_name: str, is_catalog_master: bool) -> bool:
    """Create zone in Knot DNS via knotc (only on catalog master).

    With catalog zones, zones should only be created on the master node.
    They will automatically propagate to member nodes via catalog zone.

    Args:
        zone_name: Full zone name (e.g., "g5ebqqpj740uhqtu.swarm.anthrax63.fun")
        is_catalog_master: Whether this node is the catalog master

    Returns:
        True if zone was created or already exists, False on error
    """
    try:
        # Check if zone already exists
        result = subprocess.run(
            [KNOT_CLI, "zone-status", zone_name],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode == 0:
            print(f"[*] Zone {zone_name} already exists in Knot", file=sys.stderr)
            return True

        # Only master node should create zones
        if not is_catalog_master:
            print(f"[*] Non-master node, zone {zone_name} will be synchronized from catalog", file=sys.stderr)
            return True

        # Zone doesn't exist, create it on master
        print(f"[*] Creating zone {zone_name} on catalog master", file=sys.stderr)

        # Configure zone
        result = subprocess.run(
            [KNOT_CLI, "conf-begin"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            print(f"[!] Failed to begin config transaction: {result.stderr}", file=sys.stderr)
            return False

        # Set zone with catalog template
        result = subprocess.run(
            [KNOT_CLI, "conf-set", f"zone[{zone_name}]"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            subprocess.run([KNOT_CLI, "conf-abort"], capture_output=True)
            print(f"[!] Failed to set zone: {result.stderr}", file=sys.stderr)
            return False

        # Set template to catalog (will be included in catalog zone)
        result = subprocess.run(
            [KNOT_CLI, "conf-set", f"zone[{zone_name}].template", "catalog"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            subprocess.run([KNOT_CLI, "conf-abort"], capture_output=True)
            print(f"[!] Failed to set template: {result.stderr}", file=sys.stderr)
            return False

        # Commit configuration
        result = subprocess.run(
            [KNOT_CLI, "conf-commit"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            print(f"[!] Failed to commit config: {result.stderr}", file=sys.stderr)
            return False

        # Reload Knot to apply changes
        result = subprocess.run(
            [KNOT_CLI, "reload"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            print(f"[!] Failed to reload Knot: {result.stderr}", file=sys.stderr)
            return False

        print(f"[*] Successfully created zone {zone_name} on catalog master (will sync to members)", file=sys.stderr)
        return True

    except subprocess.TimeoutExpired:
        print(f"[!] Timeout while creating zone {zone_name}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[!] Failed to create zone {zone_name}: {e}", file=sys.stderr)
        return False


def node_id_to_ns_name(node_id: str) -> str:
    """Convert node_id to DNS-compatible NS name using MD5 hash in base36."""
    md5_hash = hashlib.md5(node_id.encode()).hexdigest()
    # Convert hex to int, then to base36
    hash_int = int(md5_hash, 16)
    base36_chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    if hash_int == 0:
        return "0"
    base36 = []
    while hash_int:
        hash_int, remainder = divmod(hash_int, 36)
        base36.append(base36_chars[remainder])
    return ''.join(reversed(base36))


def register_cluster_nodes_in_powerdns(
    cluster_nodes: list,
    node_addrs: list,
    powerdns_api_url: str,
    powerdns_api_key: str,
    zone_name: str,
    base_domain: str
) -> bool:
    """Register NS delegation and glue A records for Knot cluster in PowerDNS base zone.

    Creates:
    1. NS delegation: <global_id>.<base_domain> IN NS <hash>.<global_id>.<base_domain>
    2. Glue A records: <hash>.<global_id>.<base_domain> IN A <node_ip>

    Does NOT create a separate authoritative zone in PowerDNS.
    All records are added to the base_domain zone as delegation.
    """
    try:
        headers = {
            "X-API-Key": powerdns_api_key,
            "Content-Type": "application/json"
        }

        # Subzone name to delegate: <global_id>.<base_domain>
        delegated_zone = f"{zone_name}.{base_domain}"

        # Base zone URL
        base_zone_url = f"{powerdns_api_url}/api/v1/servers/localhost/zones/{base_domain}."

        # Check if authoritative subzone exists in PowerDNS (and delete it if found)
        subzone_url = f"{powerdns_api_url}/api/v1/servers/localhost/zones/{delegated_zone}."
        print(f"[*] Checking if authoritative subzone exists: GET {subzone_url}", file=sys.stderr)

        try:
            check_response = requests.get(subzone_url, headers=headers, timeout=10)
            if check_response.status_code == 200:
                print(f"[!] Found authoritative subzone {delegated_zone}, deleting it...", file=sys.stderr)
                delete_response = requests.delete(subzone_url, headers=headers, timeout=10)
                if delete_response.status_code in [200, 204]:
                    print(f"[*] Successfully deleted authoritative subzone {delegated_zone}", file=sys.stderr)
                else:
                    print(f"[!] Failed to delete subzone: {delete_response.status_code}", file=sys.stderr)
                    print(f"[!] Response body: {delete_response.text}", file=sys.stderr)
                    return False
            elif check_response.status_code == 404:
                print(f"[*] No authoritative subzone found (good, we only need delegation)", file=sys.stderr)
        except requests.exceptions.RequestException as e:
            print(f"[!] Failed to check subzone: {e}", file=sys.stderr)
            return False

        # Get existing records from base zone
        print(f"[*] Fetching existing zone data: GET {base_zone_url}", file=sys.stderr)

        try:
            zone_response = requests.get(base_zone_url, headers=headers, timeout=10)
            if zone_response.status_code != 200:
                print(f"[!] Failed to fetch base zone {base_domain}: {zone_response.status_code}", file=sys.stderr)
                print(f"[!] Response body: {zone_response.text}", file=sys.stderr)
                return False
        except requests.exceptions.RequestException as e:
            print(f"[!] Failed to connect to PowerDNS: {e}", file=sys.stderr)
            return False

        zone_data = zone_response.json()
        rrsets = zone_data.get("rrsets", [])

        # Find existing A records under this delegated zone (for cleanup)
        existing_a_hostnames = set()
        for rrset in rrsets:
            name = rrset.get("name", "")
            # Check if it's an A record under our delegated zone
            if rrset.get("type") == "A" and name.endswith(f".{delegated_zone}."):
                existing_a_hostnames.add(name)
                print(f"[*] Found existing A record: {name}", file=sys.stderr)

        # Collect NS records and glue A records for current cluster nodes
        ns_records = []
        glue_rrsets = []
        current_a_hostnames = set()

        for node in cluster_nodes:
            node_id = node.get("node_id")
            node_addr = get_node_addr(node_id, node_addrs)

            if not node_addr:
                print(f"[!] No address found for node {node_id}", file=sys.stderr)
                continue

            # NS hostname using MD5 hash in base36
            node_hash = node_id_to_ns_name(node_id)
            ns_hostname = f"{node_hash}.{delegated_zone}."
            current_a_hostnames.add(ns_hostname)

            # Add NS record for delegation
            ns_records.append({"content": ns_hostname, "disabled": False})

            # Add glue A record
            glue_rrsets.append({
                "name": ns_hostname,
                "type": "A",
                "ttl": 300,
                "changetype": "REPLACE",
                "records": [{"content": node_addr, "disabled": False}]
            })
            print(f"[*] Will create NS delegation: {delegated_zone}. NS {ns_hostname}", file=sys.stderr)
            print(f"[*] Will create glue A record: {ns_hostname} -> {node_addr}", file=sys.stderr)

        if not ns_records:
            print(f"[!] No nameserver records to create", file=sys.stderr)
            return False

        # Find obsolete A records that need to be deleted
        obsolete_a_hostnames = existing_a_hostnames - current_a_hostnames
        for obsolete_a in obsolete_a_hostnames:
            print(f"[*] Will delete obsolete glue record: {obsolete_a}", file=sys.stderr)
            glue_rrsets.append({
                "name": obsolete_a,
                "type": "A",
                "changetype": "DELETE"
            })

        # Create NS RRset for delegation
        ns_rrset = {
            "name": f"{delegated_zone}.",
            "type": "NS",
            "ttl": 300,
            "changetype": "REPLACE",
            "records": ns_records
        }

        # Combine NS records with glue A records
        all_rrsets = [ns_rrset] + glue_rrsets
        patch_data = {"rrsets": all_rrsets}

        print(f"[*] Delegating {delegated_zone} to Knot cluster ({len(ns_records)} NS records)", file=sys.stderr)
        print(f"[*] PATCH {base_zone_url}", file=sys.stderr)

        response = requests.patch(base_zone_url, headers=headers, json=patch_data, timeout=10)

        if response.status_code in [200, 204]:
            print(f"[*] Successfully delegated {delegated_zone} to Knot DNS cluster", file=sys.stderr)
            return True
        else:
            print(f"[!] PowerDNS delegation failed: {response.status_code}", file=sys.stderr)
            print(f"[!] Response body: {response.text}", file=sys.stderr)
            return False

    except requests.exceptions.RequestException as e:
        print(f"[!] Network error while registering in PowerDNS: {e}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[!] Failed to register in PowerDNS: {e}", file=sys.stderr)
        import traceback
        print(f"[!] Traceback: {traceback.format_exc()}", file=sys.stderr)
        return False


# Plugin commands

@plugin.command('init')
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize Knot DNS: install packages."""
    try:
        # Install Knot DNS if not present
        if not is_knot_available():
            install_knot()

        return PluginOutput(status='completed', local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=str(e), local_state=input_data.local_state)


@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply Knot DNS configuration and start the service."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='error', error_message='Invalid state format', local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    knot_props = state_json.get("knotNodeProperties", [])
    cluster_props = state_json.get("clusterProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])
    node_addrs = state_json.get("nodeAddrs", [])
    cluster = state_json.get("cluster", {})

    # Check if all nodes have WireGuard configured
    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        return PluginOutput(
            status='postponed',
            error_message='Waiting for WireGuard to be configured on all nodes',
            local_state=local_state
        )

    # Get global_id (required for zone name)
    global_id = state_json.get("globalId")
    if not global_id:
        return PluginOutput(
            status='postponed',
            error_message='Waiting for global_id to be set in SwarmIdPointer table',
            local_state=local_state
        )

    # Get base_domain (required for zone name)
    base_domain = get_secret_from_swarmdb(state_json, "base_domain")
    if not base_domain:
        return PluginOutput(
            status='postponed',
            error_message='Waiting for base_domain to be set in SwarmSecrets',
            local_state=local_state
        )

    # Determine if this is leader node
    leader_node_id = get_leader_node(state_json)
    is_leader = (leader_node_id == local_node_id)
    cluster_initialized = is_cluster_initialized(knot_props)

    # Get local tunnel IP
    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        return PluginOutput(
            status='error',
            error_message='Local node has no WireGuard tunnel IP',
            local_state=local_state
        )

    # Get or generate TSIG key (leader node only, once)
    tsig_key_name = None
    tsig_key_secret = None

    for prop in cluster_props:
        if prop.get("name") == "knot_tsig_key_name":
            tsig_key_name = prop.get("value")
        elif prop.get("name") == "knot_tsig_key_secret":
            tsig_key_secret = prop.get("value")

    cluster_properties = {}

    if not tsig_key_name or not tsig_key_secret:
        if is_leader and not cluster_initialized:
            # Leader generates TSIG key on first initialization
            print(f"[*] Leader node generating TSIG key", file=sys.stderr)
            tsig_result = generate_tsig_key()
            if not tsig_result:
                return PluginOutput(
                    status='error',
                    error_message='Failed to generate TSIG key',
                    local_state=local_state
                )
            tsig_key_name, tsig_key_secret = tsig_result
            cluster_properties["knot_tsig_key_name"] = tsig_key_name
            cluster_properties["knot_tsig_key_secret"] = tsig_key_secret
            print(f"[*] Generated TSIG key: {tsig_key_name}", file=sys.stderr)
            print(f"[*] Will publish cluster_properties: {list(cluster_properties.keys())}", file=sys.stderr)
        else:
            # Non-leader or already initialized: wait for TSIG key
            return PluginOutput(
                status='postponed',
                error_message='Waiting for TSIG key to be generated by leader',
                local_state=local_state
            )

    # Determine catalog master (use leader node as catalog master)
    is_catalog_master = is_leader

    # Get catalog master IP (first node in sorted list for consistency)
    catalog_master_ip = None
    if not is_catalog_master:
        # Find leader's tunnel IP
        catalog_master_ip = get_node_tunnel_ip(leader_node_id, wg_props)
        if not catalog_master_ip:
            return PluginOutput(
                status='postponed',
                error_message='Waiting for leader node to have WireGuard tunnel IP',
                local_state=local_state
            )

    # Write Knot configuration
    try:
        write_knot_config(
            local_node_id,
            local_tunnel_ip,
            cluster_nodes,
            wg_props,
            node_addrs,
            is_catalog_master,
            tsig_key_name,
            tsig_key_secret,
            catalog_master_ip
        )
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to write config: {str(e)}', local_state=local_state)

    # Start/restart Knot DNS server
    try:
        result = subprocess.run(["systemctl", "enable", "knot"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to enable Knot: {result.stderr}', local_state=local_state)

        result = subprocess.run(["systemctl", "restart", "knot"], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status='error', error_message=f'Failed to start Knot: {result.stderr}', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to start Knot: {str(e)}', local_state=local_state)

    # Wait for Knot to become ready
    knot_ready = wait_for_knot_ready(timeout_sec=30)
    if not knot_ready:
        return PluginOutput(
            status='postponed',
            error_message='Knot DNS did not become ready within timeout',
            local_state=local_state
        )

    # Create catalog zone file (master node only)
    if is_catalog_master:
        catalog_created = create_catalog_zone_file()
        if not catalog_created:
            return PluginOutput(
                status='postponed',
                error_message='Failed to create catalog zone file',
                local_state=local_state
            )

    # Mark node as ready
    node_properties = {"knot_node_ready": "true"}

    # If this is the leader node, handle PowerDNS registration
    print(f"[DEBUG] is_leader={is_leader}, cluster_initialized={cluster_initialized}", file=sys.stderr)

    if is_leader:
        print(f"[*] This is the leader node, checking cluster initialization status", file=sys.stderr)

        if not cluster_initialized:
            print(f"[*] Cluster not yet initialized, checking if all nodes are ready", file=sys.stderr)

            # Wait for all nodes to be ready first
            if not check_all_nodes_knot_ready(cluster_nodes, knot_props, local_node_id):
                print(f"[*] Not all nodes ready yet, postponing PowerDNS registration", file=sys.stderr)
                if cluster_properties:
                    print(f"[*] Returning with cluster_properties: {list(cluster_properties.keys())}", file=sys.stderr)
                return PluginOutput(
                    status='postponed',
                    error_message='Waiting for all nodes to have Knot ready before registering in PowerDNS',
                    node_properties=node_properties,
                    cluster_properties=cluster_properties if cluster_properties else None,
                    local_state=local_state
                )

            print(f"[*] All nodes are ready, proceeding with PowerDNS registration", file=sys.stderr)

            # Get PowerDNS credentials from secrets
            powerdns_api_url = get_secret_from_swarmdb(state_json, "powerdns_api_url")
            powerdns_api_key = get_secret_from_swarmdb(state_json, "powerdns_api_key")

            print(f"[DEBUG] powerdns_api_url={'<set>' if powerdns_api_url else '<not set>'}", file=sys.stderr)
            print(f"[DEBUG] powerdns_api_key={'<set>' if powerdns_api_key else '<not set>'}", file=sys.stderr)
            print(f"[DEBUG] base_domain={base_domain}", file=sys.stderr)

            if not powerdns_api_url or not powerdns_api_key:
                print("[!] PowerDNS credentials not found in SwarmSecrets, skipping registration", file=sys.stderr)
                # Mark as initialized even without PowerDNS
                node_properties["knot_cluster_initialized"] = "true"
            else:
                # Register NS delegation and glue A records in PowerDNS
                # This delegates *.global_id.<base_domain> to the Knot cluster
                # Note: global_id is already validated at the beginning of apply()
                print(f"[*] Leader node attempting PowerDNS delegation of {global_id}.{base_domain} to Knot", file=sys.stderr)
                success = register_cluster_nodes_in_powerdns(
                    cluster_nodes,
                    node_addrs,
                    powerdns_api_url,
                    powerdns_api_key,
                    global_id,
                    base_domain
                )

                if success:
                    print(f"[*] PowerDNS registration successful, marking cluster as initialized", file=sys.stderr)
                    node_properties["knot_cluster_initialized"] = "true"
                else:
                    print(f"[!] PowerDNS registration failed, will retry on next apply", file=sys.stderr)
                    return PluginOutput(
                        status='postponed',
                        error_message='PowerDNS registration failed, retrying',
                        node_properties=node_properties,
                        cluster_properties=cluster_properties if cluster_properties else None,
                        local_state=local_state
                    )

    # Create zone in Knot (only on catalog master, will sync to members)
    delegated_zone = f"{global_id}.{base_domain}"
    zone_created = create_zone_in_knot(delegated_zone, is_catalog_master)
    if not zone_created:
        print(f"[!] Failed to create zone {delegated_zone} in Knot, will retry", file=sys.stderr)
        return PluginOutput(
            status='postponed',
            error_message=f'Failed to create zone {delegated_zone} in Knot',
            node_properties=node_properties,
            cluster_properties=cluster_properties if cluster_properties else None,
            local_state=local_state
        )

    return PluginOutput(
        status='completed',
        node_properties=node_properties,
        cluster_properties=cluster_properties if cluster_properties else None,
        local_state=local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check Knot DNS health."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Check if Knot is running
    knot_running, knot_error = is_knot_running()
    if not knot_running:
        if knot_error and 'Failed to' in knot_error:
            # Real error checking status
            return PluginOutput(status='error', error_message=knot_error, local_state=local_state)
        else:
            # Service not running yet
            return PluginOutput(status='postponed', error_message=knot_error or 'Knot service is not running', local_state=local_state)

    # Check Knot status
    try:
        result = subprocess.run(
            [KNOT_CLI, "status"],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode != 0:
            return PluginOutput(status='postponed', error_message='Knot is not responding', local_state=local_state)
    except Exception as e:
        return PluginOutput(status='postponed', error_message=f'Failed to check Knot status: {e}', local_state=local_state)

    # If this is the leader node, verify PowerDNS A records registration
    cluster = state_json.get("cluster", {})
    leader_node_id = cluster.get("leader_node")
    is_leader = (leader_node_id == local_node_id)

    if is_leader:
        knot_props = state_json.get("knotNodeProperties", [])
        cluster_initialized = is_cluster_initialized(knot_props)

        if cluster_initialized:
            # Get PowerDNS credentials and verify base zone accessibility
            powerdns_api_url = get_secret_from_swarmdb(state_json, "powerdns_api_url")
            powerdns_api_key = get_secret_from_swarmdb(state_json, "powerdns_api_key")
            base_domain = get_secret_from_swarmdb(state_json, "base_domain")
            global_id = state_json.get("globalId")

            if powerdns_api_url and powerdns_api_key and base_domain and global_id:
                try:
                    headers = {
                        "X-API-Key": powerdns_api_key,
                        "Content-Type": "application/json"
                    }
                    # Verify base zone is accessible (not subzone)
                    base_zone_url = f"{powerdns_api_url}/api/v1/servers/localhost/zones/{base_domain}."
                    check_response = requests.get(base_zone_url, headers=headers, timeout=10)

                    if check_response.status_code != 200:
                        print(f"[!] PowerDNS base zone {base_domain} check failed: {check_response.status_code}", file=sys.stderr)
                        return PluginOutput(
                            status='postponed',
                            error_message=f'PowerDNS base zone verification failed: {check_response.status_code}',
                            local_state=local_state
                        )
                    else:
                        print(f"[*] PowerDNS base zone {base_domain} verified successfully", file=sys.stderr)

                except requests.exceptions.RequestException as e:
                    print(f"[!] Failed to verify PowerDNS base zone: {e}", file=sys.stderr)
                    return PluginOutput(
                        status='postponed',
                        error_message=f'PowerDNS connectivity check failed: {str(e)}',
                        local_state=local_state
                    )

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('finalize')
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize before node removal (graceful shutdown)."""
    local_state = input_data.local_state or {}

    # TODO: Implement graceful node removal if needed
    # This could involve:
    # - Removing node from PowerDNS
    # - Waiting for DNS propagation

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy Knot DNS installation and clean up."""
    try:
        # Stop and disable Knot
        subprocess.run(["systemctl", "stop", "knot"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "knot"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Remove config and data directories
        if KNOT_CONFIG_DIR.exists():
            shutil.rmtree(KNOT_CONFIG_DIR, ignore_errors=True)
        if KNOT_DATA_DIR.exists():
            shutil.rmtree(KNOT_DATA_DIR, ignore_errors=True)

        # Request deletion of node properties
        node_properties = {
            "knot_node_ready": None,
            "knot_cluster_initialized": None,
        }

        return PluginOutput(
            status='completed',
            node_properties=node_properties,
            local_state={}
        )
    except Exception as e:
        return PluginOutput(status='error', error_message=f'Failed to destroy Knot DNS: {e}', local_state={})


if __name__ == "__main__":
    plugin.run()
