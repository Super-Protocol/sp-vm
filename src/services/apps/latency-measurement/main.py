#!/usr/bin/env python3

import sys
import os
import socket
import time
import signal
import subprocess
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
BASE_DIR = Path(os.path.expanduser("~/.swarm-latency-measurer"))
BASE_DIR.mkdir(parents=True, exist_ok=True)
PID_FILE = BASE_DIR / "udp_server.pid"
PORT_FILE = BASE_DIR / "port.txt"
DEFAULT_PORT = 9001
DEFAULT_TIMEOUT = 2.0

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def server_loop(port: int):
    """UDP ping server that responds to ping requests."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("0.0.0.0", port))
        print(f"[*] UDP server started on port {port}", file=sys.stderr)

        while True:
            try:
                sock.settimeout(1.0)
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                continue
            except Exception:
                break

            if not data:
                continue

            # Protocol: request = 0x01 + 8 bytes timestamp
            if data[0:1] == b"\x01" and len(data) >= 9:
                resp_ts_ns = time.time_ns()
                # Response: 0x02 + echo request timestamp + server timestamp
                resp = bytearray(17)
                resp[0] = 0x02
                resp[1:9] = data[1:9]  # Echo request timestamp
                resp[9:17] = resp_ts_ns.to_bytes(8, "big")

                try:
                    sock.sendto(resp, addr)
                except Exception:
                    pass
    finally:
        try:
            sock.close()
        except Exception:
            pass


def start_server(port: int) -> tuple[bool, int]:
    """Start UDP server in background. Returns (started, port)."""
    # Check if already running
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, 0)  # Check if process exists
            print(f"[*] UDP server already running with PID {pid}", file=sys.stderr)
            return False, port
        except (OSError, ValueError):
            # Process doesn't exist, clean up stale PID file
            try:
                PID_FILE.unlink()
            except Exception:
                pass

    # Start new server process
    try:
        proc = subprocess.Popen(
            [sys.executable, __file__, "--server", str(port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True
        )
        PID_FILE.write_text(str(proc.pid))
        PORT_FILE.write_text(str(port))
        print(f"[*] Started UDP server with PID {proc.pid}", file=sys.stderr)
        return True, port
    except Exception as e:
        print(f"[!] Failed to start UDP server: {e}", file=sys.stderr)
        return False, port


def stop_server():
    """Stop UDP server."""
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, signal.SIGTERM)
            print(f"[*] Sent SIGTERM to UDP server PID {pid}", file=sys.stderr)
            time.sleep(0.5)
        except (OSError, ValueError) as e:
            print(f"[!] Failed to stop server: {e}", file=sys.stderr)

        try:
            PID_FILE.unlink()
        except Exception:
            pass


def ping_node(host: str, port: int) -> float | None:
    """Ping a node and return RTT in milliseconds, or None on failure."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(DEFAULT_TIMEOUT)
        sock.connect((host, port))

        t0 = time.time_ns()

        # Build request: 0x01 + timestamp
        req = bytearray(9)
        req[0] = 0x01
        req[1:9] = t0.to_bytes(8, "big")

        sock.send(req)
        data = sock.recv(1024)

        if not data or len(data) < 17 or data[0] != 0x02:
            return None

        # Verify echoed timestamp
        req_ts = int.from_bytes(data[1:9], "big")
        if req_ts != t0:
            return None

        t1 = time.time_ns()
        rtt_ms = (t1 - t0) / 1_000_000.0

        return rtt_ms
    except Exception:
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass


def get_node_properties(state_json: dict, local_node_id: str) -> dict:
    """Extract node properties from state. Returns dict: node_id -> {prop_name: value}."""
    wg_props = state_json.get("wgNodeProperties", [])
    measurement_props = state_json.get("measurementNodeProperties", [])

    props_by_node = {}

    # Add wireguard properties (tunnel_ip)
    for prop in wg_props:
        node_id = prop.get("node_id")
        if not node_id:
            continue

        if node_id not in props_by_node:
            props_by_node[node_id] = {}

        props_by_node[node_id][prop.get("name")] = prop.get("value")

    # Add measurement properties (udp_ping_port)
    for prop in measurement_props:
        node_id = prop.get("node_id")
        if not node_id:
            continue

        if node_id not in props_by_node:
            props_by_node[node_id] = {}

        props_by_node[node_id][prop.get("name")] = prop.get("value")

    return props_by_node


# Plugin commands

@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Start UDP ping server and publish port as node property."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        state_json = {}

    # Get node properties
    props_by_node = get_node_properties(state_json, local_node_id)
    local_props = props_by_node.get(local_node_id, {})

    # Determine port: use existing property if available, otherwise default
    port = int(local_props.get("udp_ping_port", DEFAULT_PORT))

    # Start server
    started, port = start_server(port)

    # Prepare node properties
    node_properties = {}

    # Only update property if it changed or doesn't exist
    if local_props.get("udp_ping_port") != str(port):
        node_properties["udp_ping_port"] = str(port)

    # If nothing changed and server was already running, return without properties update
    if not started and not node_properties:
        return PluginOutput(status='completed', local_state=local_state)

    return PluginOutput(
        status='completed',
        node_properties=node_properties if node_properties else None,
        local_state=local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Measure latency to all other nodes and report measurements."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='completed', local_state=local_state)

    # Initialize history storage in local_state
    if "latency_history" not in local_state:
        local_state["latency_history"] = {}

    latency_history = local_state["latency_history"]

    # Get all cluster nodes
    wg_cluster_nodes = state_json.get("wgClusterNodes", [])
    props_by_node = get_node_properties(state_json, local_node_id)

    # Collect measurements
    measurements = []

    for node in wg_cluster_nodes:
        node_id = node.get("node_id")

        # Skip self
        if node_id == local_node_id:
            continue

        # Get node properties
        node_props = props_by_node.get(node_id, {})
        tunnel_ip = node_props.get("tunnel_ip")
        port_str = node_props.get("udp_ping_port")

        # Skip if missing required properties
        if not tunnel_ip or not port_str:
            continue

        try:
            port = int(port_str)
        except ValueError:
            continue

        # Ping the node
        rtt_ms = ping_node(tunnel_ip, port)

        if rtt_ms is not None:
            # Initialize history for this node if needed
            if node_id not in latency_history:
                latency_history[node_id] = []

            # Add new measurement to history
            latency_history[node_id].append(rtt_ms)

            # Keep only last 10 measurements
            if len(latency_history[node_id]) > 10:
                latency_history[node_id] = latency_history[node_id][-10:]

            # Calculate average latency
            avg_rtt_ms = sum(latency_history[node_id]) / len(latency_history[node_id])

            # Record average measurement
            measurements.append({
                "type": "latency",
                "node": local_node_id,
                "target_node": node_id,
                "value": str(round(avg_rtt_ms, 2))  # Round to 2 decimal places
            })
            print(f"[*] Measured latency to {node_id}: current={rtt_ms:.2f}ms, avg={avg_rtt_ms:.2f}ms (history: {len(latency_history[node_id])} samples)", file=sys.stderr)

    # Clean up history for nodes that no longer exist
    active_node_ids = {node.get("node_id") for node in wg_cluster_nodes if node.get("node_id") != local_node_id}
    nodes_to_remove = [node_id for node_id in latency_history.keys() if node_id not in active_node_ids]
    for node_id in nodes_to_remove:
        del latency_history[node_id]
        print(f"[*] Cleaned up history for node {node_id}", file=sys.stderr)

    print(f"[*] Collected {len(measurements)} measurements", file=sys.stderr)

    return PluginOutput(
        status='completed',
        measurements=measurements if measurements else None,
        local_state=local_state
    )


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Stop UDP server and clean up."""
    stop_server()

    # Request deletion of node property
    return PluginOutput(
        status='completed',
        node_properties={"udp_ping_port": None},
        local_state={}
    )


if __name__ == "__main__":
    # Check if running in server mode
    if len(sys.argv) >= 2 and sys.argv[1] == "--server":
        try:
            port = int(sys.argv[2]) if len(sys.argv) >= 3 else DEFAULT_PORT
        except ValueError:
            port = DEFAULT_PORT

        server_loop(port)
        sys.exit(0)

    # Run as plugin
    plugin.run()
