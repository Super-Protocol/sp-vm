#!/usr/bin/env python3
"""
Prepare swarm-db configuration by adding encryption key from swarm.key
"""

import sys
import re
import yaml
import argparse
from pathlib import Path


def prepare_swarm_db_config(base_config_path: str, key_path: str, output_path: str) -> None:
    """
    Read base config, add encryption section with key from key_path, save to output_path
    
    Args:
        base_config_path: Path to base node-db.yaml template
        key_path: Path to swarm.key file (must contain 64-char hex string)
        output_path: Path to save final config
    """
    # Check if key file exists
    if not Path(key_path).exists():
        raise FileNotFoundError(f"Encryption key file not found: {key_path}")
    
    # Read base configuration
    with open(base_config_path, 'r') as f:
        config = yaml.safe_load(f)
    
    # Read and validate encryption key
    with open(key_path, 'r') as f:
        encryption_key = f.read().strip()
    
    # Validate key format: must be 64 hex characters
    if not re.match(r'^[0-9a-fA-F]{64}$', encryption_key):
        raise ValueError(
            f"Invalid key format: must be 64 hex characters (0-9, a-f, A-F), "
            f"got {len(encryption_key)} characters"
        )
    
    # Add encryption section to memberlist
    if 'memberlist' not in config:
        config['memberlist'] = {}
    
    config['memberlist']['encryption'] = {
        'mode': 'static',
        'static_value': encryption_key
    }
    
    # Save final configuration
    with open(output_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
    
    print(f"Swarm DB config prepared successfully: {output_path}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Prepare swarm-db configuration by adding encryption key'
    )
    parser.add_argument(
        '--base-config',
        required=True,
        help='Path to base node-db.yaml template'
    )
    parser.add_argument(
        '--key-file',
        required=True,
        help='Path to swarm.key file (64-char hex string)'
    )
    parser.add_argument(
        '--output-config',
        required=True,
        help='Path to save final configuration'
    )
    
    args = parser.parse_args()
    
    try:
        prepare_swarm_db_config(args.base_config, args.key_file, args.output_config)
    except Exception as e:
        print(f"Error preparing swarm-db config: {e}", file=sys.stderr)
        sys.exit(1)
