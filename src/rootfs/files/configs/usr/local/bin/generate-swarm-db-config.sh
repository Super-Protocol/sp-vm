#!/bin/bash
set -euo pipefail

CONFIG="/sp/swarm/config.yaml"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [generate-swarm-db-config] $*"; }

cfg() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG')) or {}
v = c
for k in '$1'.split('.'):
    v = v.get(k) if isinstance(v, dict) else None
print('' if v is None else v)"
}

NODE_NAME=$(cfg "swarm_db.node_name")
ADVERTISE_ADDR=$(cfg "swarm_db.advertise_addr")

[ -z "$NODE_NAME" ] && NODE_NAME=$(hostname)

if [ -z "$ADVERTISE_ADDR" ]; then
    log "auto-detecting external IP..."
    ADVERTISE_ADDR=$(curl -sf --max-time 5 https://myip.wtf/json \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('YourFuckingIPAddress',''))" 2>/dev/null || true)
    [ -z "$ADVERTISE_ADDR" ] && \
        ADVERTISE_ADDR=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$ADVERTISE_ADDR" ]; then
        log "WARNING: could not detect external IP, using 127.0.0.1"
        ADVERTISE_ADDR="127.0.0.1"
    fi
    log "detected advertise_addr: $ADVERTISE_ADDR"
fi

log "generating /etc/swarm-db/config.yaml (node=$NODE_NAME, advertise=$ADVERTISE_ADDR)..."
mkdir -p /etc/swarm-db /var/lib/swarm-db

NODE_NAME_VAL="$NODE_NAME" ADVERTISE_ADDR_VAL="$ADVERTISE_ADDR" \
python3 - << 'PYEOF'
import yaml, os

with open('/sp/swarm/config.yaml') as f:
    swarm_cfg = yaml.safe_load(f) or {}

join_addresses = (swarm_cfg.get('swarm_db') or {}).get('join_addresses') or []

config = {
    'node': {
        'name': os.environ['NODE_NAME_VAL'],
        'host': '0.0.0.0',
        'port': 8001,
        'data_dir': '/var/lib/swarm-db',
        'schema_file': '/etc/swarm-db/schema.yaml',
    },
    'memberlist': {
        'bind_addr': '0.0.0.0',
        'bind_port': 7946,
        'advertise_addr': os.environ['ADVERTISE_ADDR_VAL'],
        'advertise_port': 7946,
        'join_addresses': join_addresses,
        'gossip_interval': '200ms',
        'probe_interval': '1s',
        'probe_timeout': '500ms',
        'suspicion_max_time_multiplier': 6,
    },
    'sql': {
        'enabled': True,
        'host': '0.0.0.0',
        'port': 3306,
        'system_database': 'swarmdb',
    },
    'jq': {
        'enabled': True,
        'host': '0.0.0.0',
        'port': 8080,
    },
}

with open('/etc/swarm-db/config.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
PYEOF

log "swarm-db config generated"
