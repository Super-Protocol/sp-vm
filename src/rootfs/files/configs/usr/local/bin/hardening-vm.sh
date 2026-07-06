#!/bin/bash

set -euo pipefail;

# Set default policy to DROP for INPUT
iptables -P INPUT DROP

# Allow established and related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow all traffic on the loopback interface
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS requests
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# Allow HTTPS (TCP 443)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Allow HTTP (TCP 80)
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# Allow HTTPS for PKI service
iptables -A INPUT -p tcp --dport 9443 -j ACCEPT

# Allow PKI VM measurements service
iptables -A INPUT -p tcp --dport 9180 -j ACCEPT

# Allow incoming traffic in the cluster network
# @TODO this will ignore NetworkPolicies in k8s, refactor in future
iptables -I INPUT -s 10.43.0.0/16 -j ACCEPT
iptables -I INPUT -s 10.42.0.0/16 -j ACCEPT
iptables -I INPUT -s 10.13.0.0/16 -j ACCEPT

# Allow podman bridge networks to reach host services (Ubuntu 24.04 podman: 10.88/16)
# Required for containers using bridge networking (e.g. harbor) to access
# host services bound to WireGuard interface
iptables -I INPUT -s 10.88.0.0/16 -j ACCEPT
iptables -I INPUT -s 10.89.0.0/16 -j ACCEPT

# Allow WireGuard (UDP 51820)
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# Allow swarm-db gossip (TCP/UDP 7946)
iptables -A INPUT -p tcp --dport 7946 -j ACCEPT
iptables -A INPUT -p udp --dport 7946 -j ACCEPT

SWARM_SECURITY_MODE_FILE="/etc/swarm/swarm-security-mode"
SWARM_SECURITY_MODE="$(head -n1 "$SWARM_SECURITY_MODE_FILE" 2>/dev/null | tr -d '[:space:]' || true)"

case "$SWARM_SECURITY_MODE" in
    untrusted)
        # Allow SSH (TCP 22)
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        systemctl start ssh
        ;;
    trusted)
        ;;
    *)
        echo "Unsupported or missing swarm security mode '$SWARM_SECURITY_MODE'; keeping SSH disabled" >&2
        ;;
esac
