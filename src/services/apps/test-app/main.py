#!/usr/bin/env python3

import os
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput


APP_PORT = int(os.environ.get("TEST_APP_PORT", "34567"))
APP_SCRIPT_PATH = Path("/usr/local/bin/test-app-server.py")
SYSTEMD_SERVICE_NAME = "test-app"
SYSTEMD_SERVICE_PATH = Path(f"/etc/systemd/system/{SYSTEMD_SERVICE_NAME}.service")


plugin = ProvisionPlugin()


class HelloWorldHandler(BaseHTTPRequestHandler):
    """Simple HTTP handler that responds with 'Hello World' to all methods."""

    def _send_hello(self):
        body = b"Hello World"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args):
        # Log to stderr with a simple prefix to avoid polluting stdout used by the plugin
        sys.stderr.write(f"[test-app] {self.address_string()} - {format % args}\n")

    def do_GET(self):
        self._send_hello()

    def do_POST(self):
        self._send_hello()

    def do_PUT(self):
        self._send_hello()

    def do_DELETE(self):
        self._send_hello()

    def do_PATCH(self):
        self._send_hello()

    def do_HEAD(self):
        # HEAD should not include body, but we still reuse status/headers
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Allow", "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS")
        self.end_headers()


def write_app_script():
    """Write the test-app HTTP server script to disk if it does not exist."""
    APP_SCRIPT_PATH.parent.mkdir(parents=True, exist_ok=True)

    script_content = f"""#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys


class HelloWorldHandler(BaseHTTPRequestHandler):
    def _send_hello(self):
        body = b"Hello World"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write(f"[test-app] {{self.address_string()}} - {{format % args}}\\n")

    def do_GET(self):
        self._send_hello()

    def do_POST(self):
        self._send_hello()

    def do_PUT(self):
        self._send_hello()

    def do_DELETE(self):
        self._send_hello()

    def do_PATCH(self):
        self._send_hello()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Allow", "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS")
        self.end_headers()


def run():
    server = HTTPServer(("0.0.0.0", {APP_PORT}), HelloWorldHandler)
    sys.stderr.write(f"[test-app] Listening on 0.0.0.0:{APP_PORT}\\n")
    server.serve_forever()


if __name__ == "__main__":
    run()
"""

    APP_SCRIPT_PATH.write_text(script_content)
    APP_SCRIPT_PATH.chmod(0o755)


def write_systemd_service():
    """Create or update systemd service unit for test-app."""
    service_content = f"""[Unit]
Description=Test App HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 {APP_SCRIPT_PATH}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
"""

    SYSTEMD_SERVICE_PATH.parent.mkdir(parents=True, exist_ok=True)
    SYSTEMD_SERVICE_PATH.write_text(service_content)

    # Reload systemd units
    subprocess.run(["systemctl", "daemon-reload"], check=False)


def is_service_running() -> tuple[bool, str | None]:
    """Check if test-app systemd service is running."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SYSTEMD_SERVICE_NAME],
            capture_output=True,
            text=True,
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


def wait_for_port_ready(timeout_sec: int = 30) -> bool:
    """Wait until APP_PORT is listening on localhost."""
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

    print(f"[!] test-app did not open port {APP_PORT} within {timeout_sec}s: {last_error}", file=sys.stderr)
    return False


@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Init is a no-op for test-app (no packages to install)."""
    local_state = input_data.local_state or {}
    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Deploy and start the test-app HTTP server."""
    local_state = input_data.local_state or {}

    try:
        write_app_script()
        write_systemd_service()
    except Exception as e:
        return PluginOutput(
            status="error",
            error_message=f"Failed to write test-app files: {e}",
            local_state=local_state,
        )

    # Enable and restart systemd service
    try:
        result = subprocess.run(
            ["systemctl", "enable", SYSTEMD_SERVICE_NAME],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return PluginOutput(
                status="error",
                error_message=f"Failed to enable {SYSTEMD_SERVICE_NAME}: {result.stderr}",
                local_state=local_state,
            )

        result = subprocess.run(
            ["systemctl", "restart", SYSTEMD_SERVICE_NAME],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return PluginOutput(
                status="error",
                error_message=f"Failed to start {SYSTEMD_SERVICE_NAME}: {result.stderr}",
                local_state=local_state,
            )
    except Exception as e:
        return PluginOutput(
            status="error",
            error_message=f"Failed to start {SYSTEMD_SERVICE_NAME}: {e}",
            local_state=local_state,
        )

    # Wait for the port to become ready
    if not wait_for_port_ready(timeout_sec=30):
        return PluginOutput(
            status="postponed",
            error_message=f"{SYSTEMD_SERVICE_NAME} did not become ready on port {APP_PORT}",
            local_state=local_state,
        )

    node_properties = {"test_app_ready": "true"}
    return PluginOutput(
        status="completed",
        node_properties=node_properties,
        local_state=local_state,
    )


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check that test-app service is running."""
    local_state = input_data.local_state or {}

    running, error = is_service_running()
    if not running:
        if error and "Failed to" in error:
            return PluginOutput(status="error", error_message=error, local_state=local_state)
        return PluginOutput(status="postponed", error_message=error or "test-app service is not running", local_state=local_state)

    # Optionally verify port is still open
    if not wait_for_port_ready(timeout_sec=5):
        return PluginOutput(
            status="postponed",
            error_message=f"{SYSTEMD_SERVICE_NAME} port {APP_PORT} is not reachable",
            local_state=local_state,
        )

    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Gracefully stop test-app before node removal."""
    local_state = input_data.local_state or {}
    try:
        subprocess.run(
            ["systemctl", "stop", SYSTEMD_SERVICE_NAME],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"[!] Failed to stop {SYSTEMD_SERVICE_NAME}: {e}", file=sys.stderr)

    return PluginOutput(status="completed", local_state=local_state)


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Completely remove test-app service and script."""
    try:
        subprocess.run(
            ["systemctl", "stop", SYSTEMD_SERVICE_NAME],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["systemctl", "disable", SYSTEMD_SERVICE_NAME],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        if SYSTEMD_SERVICE_PATH.exists():
            SYSTEMD_SERVICE_PATH.unlink()

        if APP_SCRIPT_PATH.exists():
            APP_SCRIPT_PATH.unlink()

        node_properties = {
            "test_app_ready": None,
        }

        return PluginOutput(
            status="completed",
            node_properties=node_properties,
            local_state={},
        )
    except Exception as e:
        return PluginOutput(
            status="error",
            error_message=f"Failed to destroy {SYSTEMD_SERVICE_NAME}: {e}",
            local_state={},
        )


if __name__ == "__main__":
    plugin.run()
