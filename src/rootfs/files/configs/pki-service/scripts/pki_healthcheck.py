#!/usr/bin/env python3
"""
PKI Authority health check (Podman).
Checks if the PKI Authority container is running and the service is healthy.
"""

import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pki_helpers import log, LogLevel, PKI_SERVICE_NAME, PKI_POD_NAME, PKI_CONTAINER_HTTP_PORT


def is_container_running() -> bool:
    """Check if the pki-authority pod is running."""
    try:
        result = subprocess.run(
            ["podman", "pod", "exists", PKI_POD_NAME],
            capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            log(LogLevel.INFO, f"Pod '{PKI_POD_NAME}' does not exist")
            return False

        result = subprocess.run(
            ["podman", "pod", "inspect", PKI_POD_NAME, "--format", "{{.State}}"],
            capture_output=True, text=True, check=False
        )
        state = result.stdout.strip()
        if state != "Running":
            log(LogLevel.INFO, f"Pod '{PKI_POD_NAME}' state: {state}")
            return False
        return True
    except Exception as error:
        log(LogLevel.ERROR, f"Failed to check pod status: {error}")
        return False


def is_service_healthy(healthcheck_url: str = "/healthcheck") -> bool:
    """Check if the service responds to healthcheck via published port."""
    try:
        url = f"http://127.0.0.1:{PKI_CONTAINER_HTTP_PORT}{healthcheck_url}"
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=5) as response:
            if response.status == 200:
                return True
            log(LogLevel.INFO, f"Healthcheck returned status: {response.status}")
            return False
    except Exception as error:
        log(LogLevel.INFO, f"Healthcheck failed: {error}")
        return False


def main():
    """Main health check logic."""
    log(LogLevel.INFO, "Starting PKI Authority health check")

    if not is_container_running():
        log(LogLevel.ERROR, f"Pod '{PKI_POD_NAME}' is not running")
        sys.exit(1)

    if not is_service_healthy():
        log(LogLevel.ERROR, "PKI Authority service is not healthy")
        sys.exit(1)

    log(LogLevel.INFO, "PKI Authority service is healthy")
    sys.exit(0)


if __name__ == "__main__":
    main()
