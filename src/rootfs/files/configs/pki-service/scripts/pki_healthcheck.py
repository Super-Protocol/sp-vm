#!/usr/bin/env python3
"""
PKI Authority health check.
Checks if the PKI Authority service inside the container is healthy.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pki_helpers import LXCContainer, log, LogLevel, PKI_SERVICE_NAME


def main():
    """Main health check logic."""
    log(LogLevel.INFO, "Starting PKI Authority health check")
    
    # Create container manager
    container = LXCContainer(PKI_SERVICE_NAME)
    
    # Check if container is running
    if not container.is_running():
        log(LogLevel.ERROR, f"Container '{PKI_SERVICE_NAME}' is not running")
        sys.exit(1)
    
    # Check if service inside container is healthy
    if not container.is_service_healthy():
        log(LogLevel.ERROR, "PKI Authority service is not healthy")
        sys.exit(1)
    
    log(LogLevel.INFO, "PKI Authority service is healthy")
    sys.exit(0)


if __name__ == "__main__":
    main()
