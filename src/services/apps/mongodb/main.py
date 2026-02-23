#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import json
import time
from pathlib import Path
from typing import Optional, Tuple, List, Dict

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
MONGO_PORT = int(os.environ.get("MONGO_PORT", "27017"))
MONGO_CONFIG_FILE = Path("/etc/mongod.conf")
MONGO_DATA_DIR = Path("/var/lib/mongodb")
MONGO_LOG_DIR = Path("/var/log/mongodb")
REPLICA_SET_NAME = os.environ.get("MONGO_RS", "rs0")
PRIMARY_CONNECT_POSTPONE_LIMIT = int(os.environ.get("MONGO_PRIMARY_POSTPONE_LIMIT", "5"))
PRIMARY_CONNECT_FAIL_KEY = "mongodb_primary_connect_failures"

plugin = ProvisionPlugin()

def log_event(scope: str, message: str, details: Optional[Dict] = None) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if details is None:
        print(f"{ts} [mongodb][{scope}] {message}", flush=True)
        return
    try:
        payload = json.dumps(details, ensure_ascii=False, sort_keys=True, default=str)
    except Exception:
        payload = str(details)
    print(f"{ts} [mongodb][{scope}] {message} | {payload}", flush=True)

# Helpers
def get_node_tunnel_ip(node_id: str, wg_props: List[dict]) -> Optional[str]:
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None

def check_all_nodes_have_wg(cluster_nodes: List[dict], wg_props: List[dict]) -> bool:
    for node in cluster_nodes:
        if not get_node_tunnel_ip(node.get("node_id"), wg_props):
            return False
    return True

def is_rs_initialized(mongo_props: List[dict]) -> bool:
    for prop in mongo_props:
        if prop.get("name") == "mongodb_rs_initialized" and prop.get("value") == "true":
            return True
    return False

def get_mongo_service_name() -> str:
    # Prefer "mongod", fallback to "mongodb"
    try:
        res = subprocess.run(["systemctl", "status", "mongod"], capture_output=True, text=True)
        if res.returncode in (0, 3):  # active or inactive
            return "mongod"
    except Exception:
        pass
    try:
        res = subprocess.run(["systemctl", "status", "mongodb"], capture_output=True, text=True)
        if res.returncode in (0, 3):
            return "mongodb"
    except Exception:
        pass
    return "mongod"

def is_mongo_available() -> bool:
    return shutil.which("mongod") is not None

def install_mongodb():
    # Try installing via apt (best effort, Ubuntu expected)
    if not os.path.exists("/etc/os-release"):
        raise Exception("Cannot detect OS: /etc/os-release not found")
    with open("/etc/os-release", "r") as f:
        os_release = f.read().lower()
    if "ubuntu" not in os_release:
        raise Exception("Unsupported OS for MongoDB installation")

    # Update and try packages commonly available
    res = subprocess.run(["apt-get", "update"], capture_output=True, text=True)
    if res.returncode != 0:
        raise Exception(f"apt-get update failed: {res.stderr}")

    # Prefer 'mongodb' first (may exist in Ubuntu repos), fallback to 'mongodb-org' (requires repo)
    for pkg in (["mongodb"], ["mongodb-org"]):
        res = subprocess.run(["apt-get", "install", "-y", *pkg], capture_output=True, text=True)
        if res.returncode == 0:
            return
    raise Exception("Failed to install MongoDB via apt (mongodb, mongodb-org)")

def write_mongod_config(bind_ip: str):
    MONGO_DATA_DIR.mkdir(parents=True, exist_ok=True)
    MONGO_LOG_DIR.mkdir(parents=True, exist_ok=True)
    # Minimal YAML config
    cfg = f"""# managed by provision plugin
storage:
  dbPath: {str(MONGO_DATA_DIR)}
systemLog:
  destination: file
  logAppend: true
  path: {str(MONGO_LOG_DIR)}/mongod.log
net:
  bindIp: 127.0.0.1,{bind_ip}
  port: {MONGO_PORT}
replication:
  replSetName: {REPLICA_SET_NAME}
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
"""
    MONGO_CONFIG_FILE.write_text(cfg)

def ensure_runtime_dirs():
    try:
        # Ensure data, log and runtime dirs exist and owned by mongodb
        MONGO_DATA_DIR.mkdir(parents=True, exist_ok=True)
        MONGO_LOG_DIR.mkdir(parents=True, exist_ok=True)
        run_dir = Path("/run/mongodb")
        run_dir.mkdir(parents=True, exist_ok=True)
        try:
            shutil.chown(str(MONGO_DATA_DIR), user="mongodb", group="mongodb")
            shutil.chown(str(MONGO_LOG_DIR), user="mongodb", group="mongodb")
            shutil.chown(str(run_dir), user="mongodb", group="mongodb")
        except Exception:
            # If user/group not present or chown fails, ignore; systemd tmpfiles may fix it
            pass
    except Exception:
        pass

def capture_mongo_diagnostics(svc: str) -> str:
    parts: List[str] = []
    try:
        res = subprocess.run(["systemctl", "status", svc, "--no-pager"], capture_output=True, text=True, timeout=10)
        parts.append(f"systemctl status {svc}:\n{(res.stdout or '')}\n{(res.stderr or '')}")
    except Exception as e:
        parts.append(f"systemctl status {svc} error: {e}")
    try:
        res = subprocess.run(["journalctl", "-u", svc, "-n", "200", "--no-pager"], capture_output=True, text=True, timeout=10)
        parts.append(f"journalctl -u {svc} -n 200:\n{(res.stdout or '')}\n{(res.stderr or '')}")
    except Exception as e:
        parts.append(f"journalctl fetch error: {e}")
    try:
        log_path = MONGO_LOG_DIR / "mongod.log"
        if log_path.exists():
            with open(log_path, "r") as f:
                lines = f.readlines()[-200:]
            parts.append("tail -n 200 /var/log/mongodb/mongod.log:\n" + "".join(lines))
        else:
            parts.append("mongod.log not found at /var/log/mongodb/mongod.log")
    except Exception as e:
        parts.append(f"read mongod.log error: {e}")
    return "\n\n".join(parts)

def mongo_shell_binary() -> Optional[str]:
    for b in ("mongosh", "mongo"):
        if shutil.which(b):
            return b
    return None

def mongo_eval_json(host: str, js: str, timeout: int = 10) -> Tuple[bool, Optional[dict], Optional[str]]:
    """
    Execute JS and try to parse JSON result. We wrap the expression to JSON.stringify().
    """
    bin_ = mongo_shell_binary()
    if not bin_:
        return False, None, "No mongo shell (mongosh or mongo) found"
    cmd = [
        bin_,
        f"mongodb://{host}:{MONGO_PORT}/admin",
        "--quiet",
        "--eval",
        f"try {{ let r=({js}); r = (r===undefined)? {{ok:1}} : r; print(JSON.stringify(r)); }} catch(e) {{ print(JSON.stringify({{ok:0, error:''+e}})); }}"
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (res.stdout or "").strip().splitlines()
        line = out[-1] if out else ""
        try:
            obj = json.loads(line) if line else None
        except Exception:
            obj = None
        ok = res.returncode == 0 and isinstance(obj, dict)
        return ok, obj, res.stderr
    except Exception as e:
        return False, None, str(e)

def wait_for_mongo_ready(host: str, timeout_sec: int = 60) -> bool:
    start = time.time()
    # If mongo shell not available, fallback to checking TCP port open
    if not mongo_shell_binary():
        import socket
        while time.time() - start < timeout_sec:
            try:
                with socket.create_connection((host, MONGO_PORT), timeout=2):
                    return True
            except Exception:
                time.sleep(2)
        return False
    while time.time() - start < timeout_sec:
        ok, obj, _ = mongo_eval_json(host, "db.runCommand({ping:1})", timeout=5)
        if ok and obj and obj.get("ok") == 1:
            return True
        time.sleep(2)
    return False

def is_mongo_running() -> Tuple[bool, Optional[str]]:
    try:
        svc = get_mongo_service_name()
        res = subprocess.run(["systemctl", "is-active", svc], capture_output=True, text=True)
        active = res.stdout.strip() == "active"
        return active, None if active else f"Service status: {res.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"

def rs_status(host: str) -> Tuple[Optional[dict], Optional[str]]:
    ok, obj, err = mongo_eval_json(host, "rs.status()", timeout=10)
    if ok and obj:
        return obj, None
    return None, err

def rs_initiate(host: str, members_hosts: List[str]) -> bool:
    members = [{"_id": i, "host": h} for i, h in enumerate(members_hosts)]
    js = f'rs.initiate({{ _id: "{REPLICA_SET_NAME}", members: {json.dumps(members)} }})'
    ok, obj, _ = mongo_eval_json(host, js, timeout=20)
    return bool(ok and obj and obj.get("ok") == 1)

def rs_add_missing(host: str, desired_hosts: List[str]) -> None:
    ok, current, _ = mongo_eval_json(host, "rs.conf()", timeout=10)
    if not ok or not isinstance(current, dict):
        return
    cfg = current
    existing_hosts = set()
    for m in (cfg.get("members") or []):
        h = m.get("host")
        if h:
            existing_hosts.add(h)
    for h in desired_hosts:
        if h not in existing_hosts:
            mongo_eval_json(host, f'rs.add("{h}")', timeout=15)

def split_host_port(host_or_hostport: str) -> Tuple[str, int]:
    if not host_or_hostport:
        return "", MONGO_PORT
    if ":" not in host_or_hostport:
        return host_or_hostport, MONGO_PORT
    host, port_raw = host_or_hostport.rsplit(":", 1)
    try:
        return host, int(port_raw)
    except Exception:
        return host, MONGO_PORT

def get_primary_from_local(local_host: str) -> Tuple[Optional[str], Optional[str]]:
    ok, obj, err = mongo_eval_json(local_host, "db.hello ? db.hello() : db.isMaster()", timeout=10)
    if not ok or not isinstance(obj, dict):
        return None, err or "db.hello() failed"

    if obj.get("isWritablePrimary") is True or obj.get("ismaster") is True:
        return f"{local_host}:{MONGO_PORT}", None

    primary = obj.get("primary")
    if isinstance(primary, str) and primary:
        return primary, None

    return None, "No PRIMARY in hello()"

def rs_sync_members(primary_host: str, desired_hosts: List[str]) -> Tuple[bool, Optional[str]]:
    primary_ip, primary_port = split_host_port(primary_host)
    if not primary_ip:
        return False, f"Invalid PRIMARY host: {primary_host}"
    if primary_port != MONGO_PORT:
        return False, f"PRIMARY port mismatch: got {primary_port}, expected {MONGO_PORT}"

    ok, current, err = mongo_eval_json(primary_ip, "rs.conf()", timeout=15)
    if not ok or not isinstance(current, dict):
        return False, err or "Cannot read rs.conf() from PRIMARY"

    existing_hosts = set()
    for m in (current.get("members") or []):
        h = m.get("host")
        if h:
            existing_hosts.add(h)

    desired_set = set(desired_hosts)
    to_remove = sorted(existing_hosts - desired_set)
    to_add = sorted(desired_set - existing_hosts)

    for h in to_remove:
        ok, obj, err = mongo_eval_json(primary_ip, f'rs.remove("{h}")', timeout=20)
        if not ok or not isinstance(obj, dict) or obj.get("ok") != 1:
            return False, err or f"Failed to remove member {h}: {obj}"

    for h in to_add:
        ok, obj, err = mongo_eval_json(primary_ip, f'rs.add("{h}")', timeout=20)
        if not ok or not isinstance(obj, dict) or obj.get("ok") != 1:
            return False, err or f"Failed to add member {h}: {obj}"

    return True, None

def force_local_primary(local_ip: str) -> Tuple[bool, Optional[str]]:
    local_host = f"{local_ip}:{MONGO_PORT}"

    ok, cfg, err = mongo_eval_json(local_ip, "rs.conf()", timeout=15)
    if not ok or not isinstance(cfg, dict):
        return False, err or "Cannot read rs.conf()"

    # IMPORTANT: do not copy member config from rs.conf() as-is.
    # In mongosh, numeric BSON fields (e.g. secondaryDelaySecs) may be represented
    # as nested objects and break rs.reconfig() validation.
    # Build a minimal valid member definition instead.
    # Preserve existing member _id for local host to avoid host/_id mismatch errors
    # when the same host already exists in the old configuration.
    local_member_id = 0
    for m in (cfg.get("members") or []):
        if m.get("host") == local_host:
            try:
                local_member_id = int(m.get("_id"))
            except Exception:
                local_member_id = 0
            break

    local_member = {
        "_id": local_member_id,
        "host": local_host,
        "priority": 1,
        "votes": 1,
    }

    new_cfg = {
        "_id": cfg.get("_id", REPLICA_SET_NAME),
        "version": int(cfg.get("version", 1)) + 1,
        "members": [local_member],
    }

    js = f"rs.reconfig({json.dumps(new_cfg)}, {{force: true}})"
    ok, obj, err = mongo_eval_json(local_ip, js, timeout=30)
    if ok and isinstance(obj, dict) and obj.get("ok") == 1:
        return True, None
    return False, err or f"force reconfig failed: {obj}"

# Commands
@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    try:
        if not is_mongo_available():
            install_mongodb()
        MONGO_LOG_DIR.mkdir(parents=True, exist_ok=True)
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status="error", error_message=str(e), local_state=input_data.local_state)

@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    log_event(
        "apply",
        "apply started",
        {
            "local_node_id": local_node_id,
            "state_type": type(state_json).__name__,
            "local_state_keys": sorted(list(local_state.keys())) if isinstance(local_state, dict) else [],
        },
    )

    if not isinstance(state_json, dict):
        log_event("apply", "invalid state format", {"received_type": type(state_json).__name__})
        return PluginOutput(status="error", error_message="Invalid state format", local_state=local_state)

    cluster_nodes = state_json.get("clusterNodes", [])
    mongo_props = state_json.get("mongodbNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    log_event(
        "apply",
        "parsed state",
        {
            "cluster_nodes_count": len(cluster_nodes) if isinstance(cluster_nodes, list) else None,
            "mongo_props_count": len(mongo_props) if isinstance(mongo_props, list) else None,
            "wg_props_count": len(wg_props) if isinstance(wg_props, list) else None,
        },
    )

    if not check_all_nodes_have_wg(cluster_nodes, wg_props):
        missing_wg = []
        for node in cluster_nodes:
            node_id = node.get("node_id")
            if not get_node_tunnel_ip(node_id, wg_props):
                missing_wg.append(node_id)
        log_event("apply", "postponed: waiting for WireGuard", {"missing_wg_node_ids": missing_wg})
        return PluginOutput(status="postponed", error_message="Waiting for WireGuard to be configured on all nodes", local_state=local_state)

    # Determine leader
    cluster = state_json.get("cluster", {})
    leader_node_id = cluster.get("leader_node")
    is_leader = leader_node_id == local_node_id
    initialized = is_rs_initialized(mongo_props)

    log_event(
        "apply",
        "topology state",
        {
            "leader_node_id": leader_node_id,
            "is_leader": is_leader,
            "rs_initialized": initialized,
        },
    )

    local_tunnel_ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not local_tunnel_ip:
        log_event("apply", "error: local tunnel ip not found", {"local_node_id": local_node_id})
        return PluginOutput(status="error", error_message="Local node has no WireGuard tunnel IP", local_state=local_state)

    # Write config bound to WG IP with replication enabled
    try:
        log_event("apply", "writing mongod config", {"bind_ip": local_tunnel_ip, "port": MONGO_PORT})
        write_mongod_config(local_tunnel_ip)
    except Exception as e:
        log_event("apply", "error: failed to write mongod config", {"error": str(e)})
        return PluginOutput(status="error", error_message=f"Failed to write mongod config: {e}", local_state=local_state)

    # Ensure service is running on correct IP
    ensure_runtime_dirs()
    needs_restart = False
    running, _ = is_mongo_running()
    log_event("apply", "mongo process state", {"running": running})
    if not running:
        needs_restart = True
    else:
        # best-effort ping on WG IP
        if not wait_for_mongo_ready(local_tunnel_ip, timeout_sec=5):
            needs_restart = True

    log_event("apply", "restart decision", {"needs_restart": needs_restart, "local_tunnel_ip": local_tunnel_ip})

    if needs_restart:
        try:
            svc = get_mongo_service_name()
            log_event("apply", "restarting service", {"service": svc})
            subprocess.run(["systemctl", "daemon-reload"], capture_output=True, text=True)
            subprocess.run(["systemctl", "enable", svc], capture_output=True, text=True)
            res = subprocess.run(["systemctl", "restart", svc], capture_output=True, text=True, timeout=30)
            log_event(
                "apply",
                "service restart result",
                {
                    "service": svc,
                    "returncode": res.returncode,
                    "stderr_tail": (res.stderr or "")[-400:],
                },
            )
            if res.returncode != 0:
                diag = capture_mongo_diagnostics(svc)
                log_event("apply", "error: service restart failed", {"service": svc})
                return PluginOutput(status="error", error_message=f"Failed to start {svc}: {res.stderr}\n\n{diag}", local_state=local_state)
        except Exception as e:
            svc = "mongod"
            diag = capture_mongo_diagnostics(svc)
            log_event("apply", "error: exception during service restart", {"error": str(e)})
            return PluginOutput(status="error", error_message=f"Failed to start mongod: {e}\n\n{diag}", local_state=local_state)

        if not wait_for_mongo_ready(local_tunnel_ip, timeout_sec=60):
            node_props = {"mongodb_node_ready": "false"}
            svc = get_mongo_service_name()
            diag = capture_mongo_diagnostics(svc)
            log_event("apply", "postponed: mongod not ready after restart", {"service": svc})
            return PluginOutput(status="postponed", error_message=f"mongod not ready yet\n\n{diag}", node_properties=node_props, local_state=local_state)

    # At this point local mongod is up
    node_ready_props = {"mongodb_node_ready": "true"}
    log_event("apply", "local mongod ready", {"node_ready": True})

    # Leader initializes or updates the replica set
    # Always configure a replica set even with a single node
    if is_leader and not initialized:
        # Build desired members from all cluster nodes (their WG IPs)
        desired_hosts = []
        for n in cluster_nodes:
            ip = get_node_tunnel_ip(n.get("node_id"), wg_props)
            if ip:
                desired_hosts.append(f"{ip}:{MONGO_PORT}")

        log_event("apply", "leader init path", {"desired_hosts": desired_hosts})

        # If multiple nodes, wait until all have mongod ready before initiating
        if len(cluster_nodes) > 1:
            not_ready = []
            for n in cluster_nodes:
                nid = n.get("node_id")
                ready = False
                for p in mongo_props:
                    if p.get("node_id") == nid and p.get("name") == "mongodb_node_ready" and p.get("value") == "true":
                        ready = True
                        break
                if not ready:
                    not_ready.append(nid)
            if not_ready:
                log_event("apply", "postponed: waiting for peer readiness", {"not_ready": not_ready})
                return PluginOutput(
                    status="postponed",
                    error_message=f"Waiting for nodes to be ready: {', '.join(not_ready)}",
                    node_properties=node_ready_props,
                    local_state=local_state
                )

        # Initiate replica set (single or multi-node)
        log_event("apply", "attempt rs.initiate", {"host": local_tunnel_ip, "members": desired_hosts})
        if rs_initiate(local_tunnel_ip, desired_hosts):
            # Give it a moment to elect primary
            time.sleep(3)
            done_props = {"mongodb_rs_initialized": "true", **node_ready_props}
            log_event("apply", "rs.initiate succeeded", {"mongodb_rs_initialized": True})
            return PluginOutput(status="completed", node_properties=done_props, local_state=local_state)
        else:
            log_event("apply", "postponed: rs.initiate failed")
            return PluginOutput(status="postponed", error_message="Failed to initiate replica set", node_properties=node_ready_props, local_state=local_state)

    # If already initialized, leader may add missing members
    if is_leader and initialized:
        desired_hosts = []
        for n in cluster_nodes:
            ip = get_node_tunnel_ip(n.get("node_id"), wg_props)
            if ip:
                desired_hosts.append(f"{ip}:{MONGO_PORT}")

        log_event("apply", "leader sync path", {"desired_hosts": desired_hosts})

        primary_host, primary_err = get_primary_from_local(local_tunnel_ip)
        can_use_primary = False
        if primary_host:
            primary_ip, primary_port = split_host_port(primary_host)
            can_use_primary = wait_for_mongo_ready(primary_ip, timeout_sec=5) and primary_port == MONGO_PORT

        log_event(
            "apply",
            "primary detection",
            {
                "primary_host": primary_host,
                "primary_err": primary_err,
                "can_use_primary": can_use_primary,
            },
        )

        if can_use_primary and primary_host:
            ok, sync_err = rs_sync_members(primary_host, desired_hosts)
            if not ok:
                log_event("apply", "postponed: rs sync via primary failed", {"primary_host": primary_host, "error": sync_err})
                return PluginOutput(
                    status="postponed",
                    error_message=f"Replica set sync failed via PRIMARY {primary_host}: {sync_err}",
                    node_properties=node_ready_props,
                    local_state=local_state,
                )
            local_state[PRIMARY_CONNECT_FAIL_KEY] = 0
            log_event("apply", "rs sync via primary succeeded", {"primary_host": primary_host})
        else:
            fails = int(local_state.get(PRIMARY_CONNECT_FAIL_KEY, 0)) + 1
            local_state[PRIMARY_CONNECT_FAIL_KEY] = fails
            reason = primary_err or "PRIMARY is unreachable"
            log_event(
                "apply",
                "primary unavailable",
                {
                    "fails": fails,
                    "limit": PRIMARY_CONNECT_POSTPONE_LIMIT,
                    "reason": reason,
                },
            )

            if fails < PRIMARY_CONNECT_POSTPONE_LIMIT:
                log_event("apply", "postponed: waiting for primary recovery", {"fails": fails})
                return PluginOutput(
                    status="postponed",
                    error_message=f"PRIMARY unavailable ({fails}/{PRIMARY_CONNECT_POSTPONE_LIMIT}): {reason}",
                    node_properties=node_ready_props,
                    local_state=local_state,
                )

            log_event("apply", "forcing local node to primary", {"local_tunnel_ip": local_tunnel_ip})
            forced, force_err = force_local_primary(local_tunnel_ip)
            if not forced:
                log_event("apply", "postponed: failed to force local primary", {"error": force_err})
                return PluginOutput(
                    status="postponed",
                    error_message=f"Failed to force local PRIMARY: {force_err}",
                    node_properties=node_ready_props,
                    local_state=local_state,
                )

            time.sleep(2)
            ok, sync_err = rs_sync_members(f"{local_tunnel_ip}:{MONGO_PORT}", desired_hosts)
            if not ok:
                log_event("apply", "postponed: rs sync after force failed", {"error": sync_err})
                return PluginOutput(
                    status="postponed",
                    error_message=f"Replica set sync after force failed: {sync_err}",
                    node_properties=node_ready_props,
                    local_state=local_state,
                )

            local_state[PRIMARY_CONNECT_FAIL_KEY] = 0
            log_event("apply", "rs sync after force succeeded")

    # Non-leader or after init: ensure local node reports ready
    log_event(
        "apply",
        "apply finished",
        {
            "result_status": "completed" if initialized else "postponed",
            "initialized": initialized,
            "leader_node_id": leader_node_id,
        },
    )
    return PluginOutput(status="completed" if initialized else "postponed",
                        error_message=None if initialized else f"Waiting for leader node {leader_node_id} to initialize replica set",
                        node_properties=node_ready_props,
                        local_state=local_state)

@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}
    local_node_id = input_data.local_node_id

    running, err = is_mongo_running()
    if not running:
        if err and "Failed to" in err:
            return PluginOutput(status="error", error_message=err, local_state=local_state)
        return PluginOutput(status="postponed", error_message=err or "mongod not running", local_state=local_state)

    wg_props = state_json.get("wgNodeProperties", []) if isinstance(state_json, dict) else []
    ip = get_node_tunnel_ip(local_node_id, wg_props)
    if not ip:
        return PluginOutput(status="postponed", error_message="No tunnel IP available", local_state=local_state)

    if not wait_for_mongo_ready(ip, timeout_sec=5):
        return PluginOutput(status="postponed", error_message="MongoDB ping failed", local_state=local_state)

    # Check rs.status() ok if initialized
    st, _ = rs_status(ip)
    if st and st.get("ok") == 1:
        return PluginOutput(status="completed", local_state=local_state)
    # If not initialized yet, still healthy if process is running
    return PluginOutput(status="postponed", error_message="Replica set not healthy/initialized yet", local_state=local_state)

@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    # No-op for now; graceful removal could be implemented (step down, remove member, etc.)
    return PluginOutput(status="completed", local_state=input_data.local_state or {})

@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    try:
        svc = get_mongo_service_name()
        subprocess.run(["systemctl", "stop", svc], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", svc], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        if MONGO_CONFIG_FILE.exists():
            try:
                MONGO_CONFIG_FILE.unlink()
            except Exception:
                pass
        if MONGO_DATA_DIR.exists():
            shutil.rmtree(MONGO_DATA_DIR, ignore_errors=True)
        if MONGO_LOG_DIR.exists():
            shutil.rmtree(MONGO_LOG_DIR, ignore_errors=True)

        node_properties = {
            "mongodb_node_ready": None,
            "mongodb_rs_initialized": None,
        }
        return PluginOutput(status="completed", node_properties=node_properties, local_state={})
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to destroy MongoDB: {e}", local_state={})

if __name__ == "__main__":
    plugin.run()
