#!/usr/bin/env python3
"""
PKI Authority LXC container initialization.
Creates the container from OCI archive if it doesn't exist.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pki_helpers import LXCContainer, log, LogLevel


def main():
    """Main initialization logic."""
    log(LogLevel.INFO, "Starting PKI Authority initialization")
    
    # Create container using LXCContainer class
    container = LXCContainer()
    if not container.create():
        log(LogLevel.ERROR, "Container creation failed")
        sys.exit(1)
    
    log(LogLevel.INFO, "PKI Authority initialization completed successfully")
    sys.exit(0)


if __name__ == "__main__":
    main()
