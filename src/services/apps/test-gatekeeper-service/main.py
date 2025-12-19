#!/usr/bin/env python3

import os
import socket
import subprocess
import sys
import time
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput


SERVICE_NAME = "test-gatekeeper-service"
APP_PORT = int(os.environ.get("PORT", "8081"))
TARGET_DIR = Path(f"/usr/local/lib/{SERVICE_NAME}")
LAUNCHER_BIN = TARGET_DIR / "bin" / SERVICE_NAME
SYSTEMD_SERVICE_NAME = SERVICE_NAME
SYSTEMD_SERVICE_PATH = Path(f"/etc/systemd/system/{SYSTEMD_SERVICE_NAME}.service")

RESOURCE_NAME = "sp-swarm-services"
BRANCH_NAME = "test-gatekeeper-service"
GK_ENV = os.environ.get("GATEKEEPER_ENV", "mainnet")
SSL_CERT_PATH = os.environ.get("SSL_CERT_PATH", "/etc/super/certs/gatekeeper.crt")
SSL_KEY_PATH = os.environ.get("SSL_KEY_PATH", "/etc/super/certs/gatekeeper.key")


plugin = ProvisionPlugin()


def run_downloader(target_dir: Path) -> tuple[bool, str | None]:
    """Run services-downloader CLI to fetch the gatekeeper service."""
    cmd = [
        "sp-services-downloader",
        "--resource-name", RESOURCE_NAME,
        "--branch-name", BRANCH_NAME,
        "--target-dir", str(target_dir),
        "--ssl-cert-path", SSL_CERT_PATH,
        "--ssl-key-path", SSL_KEY_PATH,
        "--environment", GK_ENV,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return False, f"downloader error: {result.stderr.strip()}"
        return True, None
    except Exception as e:
        return False, f"failed to run downloader: {e}"


def write_systemd_service() -> None:
    """Create or update systemd service unit for the gatekeeper service."""
    # Choose executable: prefer package bin, fallback to Node entry
    exec_cmd = None
    if LAUNCHER_BIN.exists():
        exec_cmd = str(LAUNCHER_BIN)
    else:
        # Fallbacks: src/index.js or dist/index.js
        for candidate in [TARGET_DIR / "server.js"]:
            if candidate.exists():
                exec_cmd = f"/usr/bin/env node {candidate}"
                break

    if exec_cmd is None:
        raise RuntimeError("service entrypoint not found in downloaded package")

    service_content = f"""[Unit]
Description=Test Gatekeeper Service
After=network.target

[Service]
Type=simple
Environment=PORT={APP_PORT}
ExecStart={exec_cmd}
WorkingDirectory={TARGET_DIR}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
"""

    SYSTEMD_SERVICE_PATH.parent.mkdir(parents=True, exist_ok=True)
    SYSTEMD_SERVICE_PATH.write_text(service_content)
    subprocess.run(["systemctl", "daemon-reload"], check=False)


def is_service_running() -> tuple[bool, str | None]:
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SYSTEMD_SERVICE_NAME],
            capture_output=True,
            text=True,
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {e}"


def wait_for_port_ready(timeout_sec: int = 30) -> bool:
    deadline = time.time() + timeout_sec
    last_error = None
    while time.time() < deadline:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        try:
            sock.connect(("127.0.0.1", APP_PORT))
            sock.close()
            return True
        except Exception as e:
            last_error = str(e)
            time.sleep(1)
        finally:
            sock.close()
    print(f"[!] {SERVICE_NAME} did not open port {APP_PORT} within {timeout_sec}s: {last_error}", file=sys.stderr)
    return False


@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Download the gatekeeper service via services-downloader."""
    local_state = input_data.local_state or {}

    TARGET_DIR.mkdir(parents=True, exist_ok=True)
    ok, err = run_downloader(TARGET_DIR)
    if not ok:
        return PluginOutput(status="postponed", error_message=err or "downloader failed", local_state=local_state)

    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Create systemd unit and start the service."""
    local_state = input_data.local_state or {}

    try:
        write_systemd_service()
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to write unit: {e}", local_state=local_state)

    try:
        subprocess.run(["systemctl", "enable", SYSTEMD_SERVICE_NAME], capture_output=True, text=True)
        result = subprocess.run(["systemctl", "restart", SYSTEMD_SERVICE_NAME], capture_output=True, text=True)
        if result.returncode != 0:
            return PluginOutput(status="error", error_message=f"Failed to start: {result.stderr}", local_state=local_state)
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to start: {e}", local_state=local_state)

    if not wait_for_port_ready(timeout_sec=30):
        return PluginOutput(status="postponed", error_message=f"{SERVICE_NAME} not ready on port {APP_PORT}", local_state=local_state)

    node_properties = {"test_gatekeeper_service_ready": "true"}
    return PluginOutput(status="completed", node_properties=node_properties, local_state=local_state)


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    local_state = input_data.local_state or {}
    running, error = is_service_running()
    if not running:
        if error and "Failed" in error:
            return PluginOutput(status="error", error_message=error, local_state=local_state)
        return PluginOutput(status="postponed", error_message=error or "service not running", local_state=local_state)

    if not wait_for_port_ready(timeout_sec=5):
        return PluginOutput(status="postponed", error_message=f"port {APP_PORT} not reachable", local_state=local_state)

    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    local_state = input_data.local_state or {}
    try:
        subprocess.run(["systemctl", "stop", SYSTEMD_SERVICE_NAME], check=False)
    except Exception as e:
        print(f"[!] Failed to stop {SYSTEMD_SERVICE_NAME}: {e}", file=sys.stderr)
    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    try:
        subprocess.run(["systemctl", "stop", SYSTEMD_SERVICE_NAME], check=False)
        subprocess.run(["systemctl", "disable", SYSTEMD_SERVICE_NAME], check=False)
        if SYSTEMD_SERVICE_PATH.exists():
            SYSTEMD_SERVICE_PATH.unlink()
        node_properties = {"test_gatekeeper_service_ready": None}
        return PluginOutput(status="completed", node_properties=node_properties, local_state={})
    except Exception as e:
        return PluginOutput(status="error", error_message=f"Failed to destroy: {e}", local_state={})


if __name__ == "__main__":
    plugin.run()
