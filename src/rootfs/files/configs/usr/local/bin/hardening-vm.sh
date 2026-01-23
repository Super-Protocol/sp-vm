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

# Allow incoming traffic in the cluster network
# @TODO this will ignore NetworkPolicies in k8s, refactor in future
iptables -I INPUT -s 10.43.0.0/16 -j ACCEPT
iptables -I INPUT -s 10.42.0.0/16 -j ACCEPT
iptables -I INPUT -s 10.13.0.0/16 -j ACCEPT

# Allow WireGuard (UDP 51820)
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# Allow swarm-db gossip (TCP/UDP 7946)
iptables -A INPUT -p tcp --dport 7946 -j ACCEPT
iptables -A INPUT -p udp --dport 7946 -j ACCEPT

# Allow DHCP for LXC containers (client:68 -> server:67)
iptables -A INPUT -i lxcbr0 -p udp --sport 68 --dport 67 -j ACCEPT

# if NOT DEBUG, then close VM via firewall
if grep -q 'sp-debug=true' /proc/cmdline; then
    # Allow SSH (TCP 22)
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    systemctl start ssh
fi