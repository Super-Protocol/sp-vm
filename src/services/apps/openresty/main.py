#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess
import hashlib
import time
import json
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
OPENRESTY_CONFIG_DIR = Path("/usr/local/openresty/nginx/conf")
OPENRESTY_CONFIG_FILE = OPENRESTY_CONFIG_DIR / "nginx.conf"
OPENRESTY_SSL_DIR = OPENRESTY_CONFIG_DIR / "ssl"
OPENRESTY_LOG_DIR = Path("/var/log/openresty")
NGINX_LOGS_DIR = Path("/usr/local/openresty/nginx/logs")

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def get_node_tunnel_ip(node_id: str, wg_props: list) -> str | None:
    """Get WireGuard tunnel IP for a node."""
    for prop in wg_props:
        if prop.get("node_id") == node_id and prop.get("name") == "tunnel_ip":
            return prop.get("value")
    return None


def get_redis_tunnel_ips(state_json: dict) -> list[str]:
    """Get tunnel IPs of all ready Redis nodes."""
    redis_node_props = state_json.get("redisNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    redis_hosts = []
    for prop in redis_node_props:
        if prop.get("name") == "redis_node_ready" and prop.get("value") == "true":
            node_id = prop.get("node_id")
            tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
            if tunnel_ip:
                redis_hosts.append(tunnel_ip)

    return sorted(set(redis_hosts))


def get_knot_tunnel_ips(state_json: dict) -> list[str]:
    """Get tunnel IPs of all ready Knot DNS nodes."""
    knot_node_props = state_json.get("knotNodeProperties", [])
    wg_props = state_json.get("wgNodeProperties", [])

    knot_hosts = []
    for prop in knot_node_props:
        if prop.get("name") == "knot_node_ready" and prop.get("value") == "true":
            node_id = prop.get("node_id")
            tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
            if tunnel_ip:
                knot_hosts.append(tunnel_ip)

    return sorted(set(knot_hosts))


def get_knot_leader_tunnel_ip(state_json: dict) -> str | None:
    """Get tunnel IP of Knot cluster leader node."""
    knot_cluster = state_json.get("knotCluster", {})
    leader_node_id = knot_cluster.get("leader_node")

    if not leader_node_id:
        return None

    wg_props = state_json.get("wgNodeProperties", [])
    return get_node_tunnel_ip(leader_node_id, wg_props)


def get_node_addr(node_id: str, node_addrs: list) -> str | None:
    """Get physical address for a node."""
    for node in node_addrs:
        if node.get("node_id") == node_id:
            return node.get("addr")
    return None


def get_secret_from_swarmdb(state_json: dict, secret_id: str) -> str | None:
    """Get secret value from SwarmSecrets table."""
    secrets = state_json.get("swarmSecrets", [])
    for secret in secrets:
        if secret.get("id") == secret_id:
            return secret.get("value")
    return None


def get_leader_node(state_json: dict) -> str | None:
    """Get leader node ID from cluster info."""
    cluster = state_json.get("cluster", {})
    return cluster.get("leader_node")


def send_dns_update(
    knot_server: str,
    zone_name: str,
    hostname: str,
    record_type: str,
    records: list[str],
    tsig_key_name: str,
    tsig_key_secret: str,
    ttl: int = 300
) -> bool:
    """Send RFC 2136 DNS UPDATE to Knot server using nsupdate with TSIG authentication.

    Args:
        knot_server: IP address of Knot DNS server
        zone_name: Zone name (e.g., "g5ebqqpj740uhqtu.swarm.anthrax63.fun")
        hostname: Hostname to update (e.g., "gw.g5ebqqpj740uhqtu.swarm.anthrax63.fun")
        record_type: Record type (A, AAAA, CNAME, etc.)
        records: List of record values
        tsig_key_name: TSIG key name for authentication
        tsig_key_secret: TSIG key secret (base64)
        ttl: TTL in seconds

    Returns:
        True if update was successful, False otherwise
    """
    try:
        # Build nsupdate script with TSIG authentication
        nsupdate_script = f"""server {knot_server}
key hmac-sha256:{tsig_key_name} {tsig_key_secret}
zone {zone_name}.
update delete {hostname}. {record_type}
"""
        # Then add new records
        for record in records:
            nsupdate_script += f"update add {hostname}. {ttl} {record_type} {record}\n"

        nsupdate_script += "send\n"

        print(f"[*] Sending DNS UPDATE to {knot_server} for {hostname} {record_type} (TSIG: {tsig_key_name})", file=sys.stderr)

        # Execute nsupdate
        result = subprocess.run(
            ["nsupdate"],
            input=nsupdate_script,
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            print(f"[!] nsupdate failed: {result.stderr}", file=sys.stderr)
            return False

        print(f"[*] Successfully updated DNS: {hostname} {record_type} -> {records}", file=sys.stderr)
        return True

    except subprocess.TimeoutExpired:
        print(f"[!] nsupdate timed out", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[!] Failed to send DNS UPDATE: {e}", file=sys.stderr)
        import traceback
        print(f"[!] Traceback: {traceback.format_exc()}", file=sys.stderr)
        return False


def get_knot_tsig_key(state_json: dict) -> tuple[str, str] | None:
    """Get TSIG key from Knot cluster properties.

    Returns:
        (tsig_key_name, tsig_key_secret) tuple or None if not found
    """
    knot_cluster = state_json.get("knotCluster", {})
    if not knot_cluster.get("id"):
        return None

    # Get cluster properties for knot cluster
    # Note: we need to fetch from knotClusterProperties if available
    knot_props = state_json.get("knotClusterProperties", [])

    tsig_key_name = None
    tsig_key_secret = None

    for prop in knot_props:
        if prop.get("name") == "knot_tsig_key_name":
            tsig_key_name = prop.get("value")
        elif prop.get("name") == "knot_tsig_key_secret":
            tsig_key_secret = prop.get("value")

    if tsig_key_name and tsig_key_secret:
        return (tsig_key_name, tsig_key_secret)

    return None


def update_gateway_dns_records(
    knot_leader_tunnel_ip: str,
    cluster_nodes: list,
    node_addrs: list,
    global_id: str,
    base_domain: str,
    tsig_key_name: str,
    tsig_key_secret: str
) -> bool:
    """Update A records for gw.<swarm_id>.<base_domain> in Knot DNS via DNS UPDATE."""
    # Full zone name: <global_id>.<base_domain>
    full_zone_name = f"dyn.{global_id}.{base_domain}"
    gw_hostname = f"gw.{full_zone_name}"

    # Collect A records for all openresty nodes
    a_records = []
    for node in cluster_nodes:
        node_id = node.get("node_id")
        node_addr = get_node_addr(node_id, node_addrs)
        if node_addr:
            a_records.append(node_addr)

    if not a_records:
        print(f"[!] No A records to set for {gw_hostname}", file=sys.stderr)
        return False

    if not knot_leader_tunnel_ip:
        print(f"[!] No Knot DNS leader tunnel IP available", file=sys.stderr)
        return False

    # Send DNS UPDATE to Knot leader node
    print(f"[*] Sending DNS UPDATE to Knot leader: {knot_leader_tunnel_ip}", file=sys.stderr)

    return send_dns_update(
        knot_server=knot_leader_tunnel_ip,
        zone_name=full_zone_name,
        hostname=gw_hostname,
        record_type="A",
        records=a_records,
        tsig_key_name=tsig_key_name,
        tsig_key_secret=tsig_key_secret,
        ttl=300
    )


def compute_config_hash(redis_hosts: list[str]) -> str:
    """Compute hash of configuration based on Redis hosts."""
    payload = "|".join(sorted(redis_hosts))
    return hashlib.sha256(payload.encode()).hexdigest()


def is_openresty_available() -> bool:
    """Check if OpenResty binary is available."""
    return Path("/usr/local/openresty/bin/openresty").exists()


def is_luarocks_package_installed(package_name: str) -> bool:
    """Check if a luarocks package is already installed."""
    try:
        result = subprocess.run(
            ["luarocks", "show", package_name],
            capture_output=True,
            text=True,
            check=False
        )
        return result.returncode == 0
    except Exception:
        return False


def install_openresty():
    """Install OpenResty and required dependencies."""
    try:
        # Detect OS
        if not os.path.exists("/etc/os-release"):
            raise Exception("Cannot detect OS: /etc/os-release not found")

        with open("/etc/os-release", "r") as f:
            os_release = f.read()

        # Check for Ubuntu
        if "ubuntu" not in os_release.lower():
            raise Exception("Only Ubuntu is supported for OpenResty installation")

        # Install prerequisites
        result = subprocess.run(
            ["apt-get", "update"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"apt-get update failed: {result.stderr}")

        result = subprocess.run(
            ["apt-get", "install", "-y", "--no-install-recommends",
             "wget", "gnupg", "ca-certificates", "lsb-release"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to install prerequisites: {result.stderr}")

        # Add OpenResty APT repository
        result = subprocess.run(
            ["wget", "-O", "-", "https://openresty.org/package/pubkey.gpg"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to download GPG key: {result.stderr}")

        gpg_result = subprocess.run(
            ["apt-key", "add", "-"],
            input=result.stdout,
            capture_output=True,
            text=True
        )
        if gpg_result.returncode != 0:
            raise Exception(f"Failed to add GPG key: {gpg_result.stderr}")

        # Get Ubuntu codename
        result = subprocess.run(
            ["lsb_release", "-sc"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to get Ubuntu codename: {result.stderr}")

        codename = result.stdout.strip()
        repo_line = f"deb http://openresty.org/package/ubuntu {codename} main"

        with open("/etc/apt/sources.list.d/openresty.list", "w") as f:
            f.write(repo_line + "\n")

        # Update package list
        result = subprocess.run(
            ["apt-get", "update"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"apt-get update failed after adding repo: {result.stderr}")

        # Install OpenResty
        result = subprocess.run(
            ["apt-get", "install", "-y", "openresty"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"OpenResty installation failed: {result.stderr}")

        # Install luarocks
        result = subprocess.run(
            ["apt-get", "install", "-y", "luarocks"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            raise Exception(f"Luarocks installation failed: {result.stderr}")

        # Install Lua modules
        lua_modules = [
            "lua-resty-auto-ssl",
            "lua-resty-redis",
            "lua-resty-http"
        ]

        for module in lua_modules:
            if not is_luarocks_package_installed(module):
                print(f"[*] Installing {module}", file=sys.stderr)
                result = subprocess.run(
                    ["luarocks", "install", module],
                    capture_output=True,
                    text=True
                )
                if result.returncode != 0:
                    print(f"[!] Warning: Failed to install {module}: {result.stderr}", file=sys.stderr)

        print("[*] OpenResty installation completed", file=sys.stderr)

    except Exception as e:
        print(f"[!] Failed to install OpenResty: {e}", file=sys.stderr)
        raise


def generate_nginx_config(redis_hosts: list[str]) -> str:
    """Generate Nginx configuration content."""
    redis_host_list = ", ".join([f'"{host}:6379"' for host in redis_hosts])

    config = f"""# Nginx/OpenResty configuration for Gateway with AutoSSL, SSL Passthrough and Redis routing

user www-data;
worker_processes auto;
pid /usr/local/openresty/nginx/logs/nginx.pid;

events {{
    worker_connections 1024;
}}

# Stream block for SSL passthrough routing (port 443)
stream {{
    # Logging
    log_format basic '$remote_addr [$time_local] '
                     '$protocol $status $bytes_sent $bytes_received '
                     '$session_time';
    
    access_log /var/log/openresty/stream-access.log basic;
    error_log /var/log/openresty/stream-error.log info;

    # Shared memory zones
    lua_shared_dict stream_route_cache 10m;
    lua_shared_dict stream_rr_counters 10m;

    # Redis hosts
    init_by_lua_block {{
        stream_redis_hosts = {{{redis_host_list}}}
    }}

    # SSL preread to get SNI hostname
    ssl_preread on;

    server {{
        listen 443;
        
        # Variable for dynamic upstream
        set $upstream_target "";
        
        # Lua code to route based on passthrough flag
        preread_by_lua_block {{
            local redis = require "resty.redis"
            local cjson = require "cjson"
            local domain = ngx.var.ssl_preread_server_name
            
            if not domain or domain == "" then
                -- No SNI, close connection
                return ngx.exit(421)
            end

            -- Try to get route from cache
            local cache = ngx.shared.stream_route_cache
            local cached_route = cache:get(domain)

            if not cached_route then
                -- Query Redis for route
                local red = redis:new()
                red:set_timeout(1000)

                local route_data = nil
                for _, host in ipairs(stream_redis_hosts) do
                    local ok, err = red:connect(host:match("([^:]+)"), tonumber(host:match(":(%d+)")) or 6379)
                    if ok then
                        local route, err = red:get("routes:" .. domain)
                        if route and route ~= ngx.null then
                            route_data = route
                            red:close()
                            break
                        end
                        red:close()
                    end
                end

                if not route_data then
                    -- No route found, close connection
                    return ngx.exit(421)
                end

                -- Cache for 30 seconds
                cache:set(domain, route_data, 30)
                cached_route = route_data
            end

            -- Parse route configuration
            local route = cjson.decode(cached_route)
            local passthrough = route.passthrough or false

            if not passthrough then
                -- SSL termination mode: proxy to local HTTP server
                ngx.var.upstream_target = "127.0.0.1:8443"
                return
            end

            -- Passthrough mode: select backend target
            local targets = route.targets or {{}}

            if #targets == 0 then
                return ngx.exit(421)
            end

            -- Select target based on policy
            local policy = route.policy or "rr"
            local target_url

            if policy == "rr" then
                -- Round-robin
                local counters = ngx.shared.stream_rr_counters
                local counter = counters:get(domain) or 0
                local idx = (counter % #targets) + 1
                target_url = targets[idx].url
                counters:incr(domain, 1, 0)

            elseif policy == "ip_hash" then
                -- IP hash
                local ip = ngx.var.remote_addr
                local hash = ngx.crc32_long(ip)
                local idx = (hash % #targets) + 1
                target_url = targets[idx].url

            else
                -- Default to first target
                target_url = targets[1].url
            end

            -- Extract host and port from URL
            -- Format: https://host:port or http://host:port
            local backend_host, backend_port = target_url:match("^https?://([^:/]+):?(%d*)/?")
            
            if not backend_host then
                return ngx.exit(421)
            end
            
            -- Default port to 443 if not specified and using https
            if not backend_port or backend_port == "" then
                if target_url:match("^https://") then
                    backend_port = "443"
                else
                    backend_port = "80"
                end
            end

            ngx.var.upstream_target = backend_host .. ":" .. backend_port
        }}

        proxy_pass $upstream_target;
        proxy_connect_timeout 5s;
    }}
}}

http {{
    include /usr/local/openresty/nginx/conf/mime.types;
    default_type application/octet-stream;

    # Logging
    access_log /var/log/openresty/access.log;
    error_log /var/log/openresty/error.log;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Lua package path
    lua_package_path "/usr/local/openresty/site/lualib/?.lua;;";
    lua_shared_dict auto_ssl 1m;
    lua_shared_dict auto_ssl_settings 64k;
    lua_shared_dict route_cache 10m;
    lua_shared_dict rr_counters 10m;

    # Redis hosts for backend storage
    init_by_lua_block {{
        redis_hosts = {{{redis_host_list}}}

        -- Auto-SSL setup
        auto_ssl = (require "resty.auto-ssl").new()
        auto_ssl:set("allow_domain", function(domain)
            -- Check if route exists in Redis for this domain
            local redis = require "resty.redis"
            local red = redis:new()
            red:set_timeout(1000)

            for _, host in ipairs(redis_hosts) do
                local ok, err = red:connect(host:match("([^:]+)"), tonumber(host:match(":(%d+)")) or 6379)
                if ok then
                    local route, err = red:get("routes:" .. domain)
                    red:close()
                    if route and route ~= ngx.null then
                        return true
                    end
                end
            end
            return false
        end)
        auto_ssl:init()
    }}

    init_worker_by_lua_block {{
        auto_ssl:init_worker()
    }}

    # ACME challenge server (internal)
    server {{
        listen 127.0.0.1:8999;
        client_body_buffer_size 128k;
        client_max_body_size 128k;
        location / {{
            content_by_lua_block {{
                auto_ssl:hook_server()
            }}
        }}
    }}

    # HTTP server (port 80)
    server {{
        listen 80;
        server_name _;

        # ACME challenge location
        location /.well-known/acme-challenge/ {{
            content_by_lua_block {{
                auto_ssl:challenge_server()
            }}
        }}

        # Redirect all other traffic to HTTPS
        location / {{
            return 301 https://$host$request_uri;
        }}
    }}

    # HTTPS server (port 8443 - for SSL termination via stream proxy)
    server {{
        listen 127.0.0.1:8443 ssl;
        server_name _;

        # Declare variable for use in proxy_pass
        set $upstream_url "";

        # Auto-SSL certificates
        ssl_certificate_by_lua_block {{
            auto_ssl:ssl_certificate()
        }}
        ssl_certificate /usr/local/openresty/nginx/conf/ssl/fallback.crt;
        ssl_certificate_key /usr/local/openresty/nginx/conf/ssl/fallback.key;

        location / {{
            access_by_lua_block {{
                local redis = require "resty.redis"
                local cjson = require "cjson"
                local domain = ngx.var.host

                -- Try to get route from cache
                local cache = ngx.shared.route_cache
                local cached_route = cache:get(domain)

                if not cached_route then
                    -- Query Redis for route
                    local red = redis:new()
                    red:set_timeout(1000)

                    local route_data = nil
                    for _, host in ipairs(redis_hosts) do
                        local ok, err = red:connect(host:match("([^:]+)"), tonumber(host:match(":(%d+)")) or 6379)
                        if ok then
                            local route, err = red:get("routes:" .. domain)
                            if route and route ~= ngx.null then
                                route_data = route
                                red:close()
                                break
                            end
                            red:close()
                        end
                    end

                    if not route_data then
                        ngx.status = 404
                        ngx.say("No route configured for this domain")
                        return ngx.exit(404)
                    end

                    -- Cache for 30 seconds
                    cache:set(domain, route_data, 30)
                    cached_route = route_data
                end

                -- Parse route configuration
                local route = cjson.decode(cached_route)
                local targets = route.targets or {{}}

                if #targets == 0 then
                    ngx.status = 503
                    ngx.say("No backend targets available")
                    return ngx.exit(503)
                end

                -- Select target based on policy
                local policy = route.policy or "rr"
                local target_url

                if policy == "rr" then
                    -- Round-robin
                    local counters = ngx.shared.rr_counters
                    local counter = counters:get(domain) or 0
                    local total_weight = 0
                    for _, t in ipairs(targets) do
                        total_weight = total_weight + (t.weight or 1)
                    end

                    local idx = (counter % #targets) + 1
                    target_url = targets[idx].url
                    counters:incr(domain, 1, 0)

                elseif policy == "ip_hash" then
                    -- IP hash
                    local ip = ngx.var.remote_addr
                    local hash = ngx.crc32_long(ip)
                    local idx = (hash % #targets) + 1
                    target_url = targets[idx].url

                elseif policy == "cookie" then
                    -- Cookie-based sticky session
                    local cookie_name = route.cookie_name or "sticky"
                    local cookie_value = ngx.var["cookie_" .. cookie_name]

                    if not cookie_value then
                        -- Assign new cookie
                        local idx = math.random(#targets)
                        target_url = targets[idx].url
                        cookie_value = tostring(idx)
                        ngx.header["Set-Cookie"] = cookie_name .. "=" .. cookie_value .. "; Path=/; HttpOnly"
                    else
                        local idx = tonumber(cookie_value) or 1
                        if idx < 1 or idx > #targets then
                            idx = 1
                        end
                        target_url = targets[idx].url
                    end
                else
                    -- Default to first target
                    target_url = targets[1].url
                end

                -- Set upstream variable
                ngx.var.upstream_url = target_url

                -- Set Host header based on preserve_host
                if route.preserve_host then
                    ngx.req.set_header("Host", domain)
                end
            }}

            # Proxy to selected backend
            proxy_set_header Host $host;
            proxy_pass $upstream_url;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }}
    }}
}}
"""
    return config


def write_nginx_config(config_content: str):
    """Write Nginx configuration to disk and setup required directories."""
    # Ensure config directory exists
    OPENRESTY_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    # Ensure log directory exists
    OPENRESTY_LOG_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["chown", "-R", "www-data:www-data", str(OPENRESTY_LOG_DIR)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    # Ensure nginx logs directory exists (for PID file)
    NGINX_LOGS_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["chown", "-R", "www-data:www-data", str(NGINX_LOGS_DIR)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    # Write configuration
    OPENRESTY_CONFIG_FILE.write_text(config_content)
    print(f"[*] Wrote Nginx config to {OPENRESTY_CONFIG_FILE}", file=sys.stderr)

    # Create SSL directory and self-signed fallback certificate if not exists
    OPENRESTY_SSL_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["chown", "-R", "www-data:www-data", str(OPENRESTY_SSL_DIR)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    fallback_cert = OPENRESTY_SSL_DIR / "fallback.crt"
    if not fallback_cert.exists():
        # Generate self-signed certificate as fallback
        subprocess.run(
            [
                "openssl", "req", "-new", "-newkey", "rsa:2048", "-days", "3650",
                "-nodes", "-x509", "-subj", "/CN=fallback",
                "-keyout", str(OPENRESTY_SSL_DIR / "fallback.key"),
                "-out", str(OPENRESTY_SSL_DIR / "fallback.crt")
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )


def is_openresty_running() -> tuple[bool, str | None]:
    """Check if OpenResty is running.
    Returns (is_running, error_message)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "openresty"],
            capture_output=True,
            text=True
        )
        is_active = result.stdout.strip() == "active"
        return is_active, None if is_active else f"Service status: {result.stdout.strip()}"
    except Exception as e:
        return False, f"Failed to check service status: {str(e)}"


# Plugin commands

@plugin.command('init')
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize OpenResty: install packages."""
    try:
        # Install OpenResty if not present
        if not is_openresty_available():
            install_openresty()

        return PluginOutput(status='completed', local_state=input_data.local_state)
    except Exception as e:
        return PluginOutput(status='error', error_message=str(e), local_state=input_data.local_state)


@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply OpenResty configuration and start the service."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Ensure state_json is a dict
    if not isinstance(state_json, dict):
        return PluginOutput(status='error', error_message='Invalid state format', local_state=local_state)

    # Get Redis hosts from state
    redis_hosts = get_redis_tunnel_ips(state_json)

    if not redis_hosts:
        return PluginOutput(
            status='postponed',
            error_message='Waiting for Redis nodes to become ready',
            local_state=local_state
        )

    print(f"[*] Found {len(redis_hosts)} Redis hosts: {redis_hosts}", file=sys.stderr)

    # Compute config hash to detect changes
    config_hash = compute_config_hash(redis_hosts)

    # Check if we need to reconfigure
    prev_config_hash = local_state.get("config_hash")
    if prev_config_hash == config_hash and local_state.get("openresty_ready"):
        # No changes, skip reconfiguration
        return PluginOutput(status='completed', local_state=local_state)

    # Generate and write configuration
    try:
        config_content = generate_nginx_config(redis_hosts)
        write_nginx_config(config_content)
    except Exception as e:
        return PluginOutput(
            status='error',
            error_message=f'Failed to write config: {str(e)}',
            local_state=local_state
        )

    # Start or reload OpenResty
    try:
        openresty_running, _ = is_openresty_running()

        if openresty_running and prev_config_hash:
            # Config changed, reload
            print("[*] Configuration changed, reloading OpenResty", file=sys.stderr)
            result = subprocess.run(
                ["systemctl", "reload", "openresty"],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                # Reload failed, try restart
                print("[!] Reload failed, restarting OpenResty", file=sys.stderr)
                result = subprocess.run(
                    ["systemctl", "restart", "openresty"],
                    capture_output=True,
                    text=True
                )
                if result.returncode != 0:
                    return PluginOutput(
                        status='error',
                        error_message=f'Failed to restart OpenResty: {result.stderr}',
                        local_state=local_state
                    )
        else:
            # First time or not running, start
            print("[*] Starting OpenResty", file=sys.stderr)
            result = subprocess.run(
                ["systemctl", "enable", "openresty"],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                return PluginOutput(
                    status='error',
                    error_message=f'Failed to enable OpenResty: {result.stderr}',
                    local_state=local_state
                )

            result = subprocess.run(
                ["systemctl", "start", "openresty"],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                return PluginOutput(
                    status='error',
                    error_message=f'Failed to start OpenResty: {result.stderr}',
                    local_state=local_state
                )

    except Exception as e:
        return PluginOutput(
            status='error',
            error_message=f'Failed to start OpenResty: {str(e)}',
            local_state=local_state
        )

    # Wait a bit for OpenResty to start
    time.sleep(2)

    # Update local state
    new_local_state = {
        **local_state,
        "config_hash": config_hash,
        "redis_hosts": redis_hosts,
        "openresty_ready": True
    }

    # Prepare node properties
    node_properties = {
        "openresty_ready": "true"
    }

    # If this is the leader node, update gateway DNS records
    cluster_nodes = state_json.get("clusterNodes", [])
    node_addrs = state_json.get("nodeAddrs", [])
    leader_node_id = get_leader_node(state_json)
    is_leader = (leader_node_id == local_node_id)

    if is_leader:
        print(f"[*] This is the leader node, updating gateway DNS records", file=sys.stderr)

        # Get global_id and base_domain
        global_id = state_json.get("globalId")
        base_domain = get_secret_from_swarmdb(state_json, "base_domain")

        print(f"[DEBUG] global_id={global_id}, base_domain={base_domain}", file=sys.stderr)

        if global_id and base_domain:
            # Get Knot DNS leader tunnel IP
            knot_leader_tunnel_ip = get_knot_leader_tunnel_ip(state_json)
            print(f"[DEBUG] Knot leader tunnel IP: {knot_leader_tunnel_ip}", file=sys.stderr)

            # Get TSIG key from Knot cluster properties
            tsig_result = get_knot_tsig_key(state_json)
            print(f"[DEBUG] TSIG key available: {tsig_result is not None}", file=sys.stderr)

            if knot_leader_tunnel_ip and tsig_result:
                tsig_key_name, tsig_key_secret = tsig_result
                print(f"[DEBUG] TSIG key name: {tsig_key_name}", file=sys.stderr)

                # Collect A records info for logging
                a_records_count = len([n for n in cluster_nodes if get_node_addr(n.get("node_id"), node_addrs)])
                print(f"[DEBUG] Will register {a_records_count} A records for gateway", file=sys.stderr)

                # Update DNS records for gw.<swarm_id>.<base_domain>
                dns_updated = update_gateway_dns_records(
                    knot_leader_tunnel_ip,
                    cluster_nodes,
                    node_addrs,
                    global_id,
                    base_domain,
                    tsig_key_name,
                    tsig_key_secret
                )

                if dns_updated:
                    print(f"[*] Gateway DNS records updated successfully", file=sys.stderr)
                    node_properties["openresty_dns_updated"] = "true"
                else:
                    print(f"[!] Failed to update gateway DNS records, will retry", file=sys.stderr)
                    return PluginOutput(
                        status='postponed',
                        error_message='Failed to update gateway DNS records in Knot',
                        local_state=new_local_state
                    )
            else:
                if not knot_leader_tunnel_ip:
                    knot_cluster = state_json.get("knotCluster", {})
                    leader_node_id = knot_cluster.get("leader_node")
                    print(f"[!] No Knot DNS leader tunnel IP available", file=sys.stderr)
                    print(f"[DEBUG] Knot cluster: {knot_cluster}", file=sys.stderr)
                    print(f"[DEBUG] Knot leader_node_id: {leader_node_id}", file=sys.stderr)
                    wg_props_count = len(state_json.get("wgNodeProperties", []))
                    print(f"[DEBUG] WireGuard properties count: {wg_props_count}", file=sys.stderr)
                if not tsig_result:
                    cluster_props = state_json.get("knotClusterProperties", [])
                    print(f"[!] No TSIG key available from Knot cluster", file=sys.stderr)
                    print(f"[DEBUG] Knot cluster properties count: {len(cluster_props)}", file=sys.stderr)
                    for prop in cluster_props:
                        print(f"[DEBUG]   - {prop.get('name')}: {'<set>' if prop.get('value') else '<empty>'}", file=sys.stderr)
        else:
            if not global_id:
                print(f"[!] Missing global_id, skipping DNS update", file=sys.stderr)
            if not base_domain:
                secrets = state_json.get("swarmSecrets", [])
                print(f"[!] Missing base_domain, skipping DNS update", file=sys.stderr)
                print(f"[DEBUG] Available secrets: {[s.get('id') for s in secrets]}", file=sys.stderr)

    return PluginOutput(
        status='completed',
        node_properties=node_properties,
        local_state=new_local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check OpenResty health."""
    local_node_id = input_data.local_node_id
    state_json = input_data.state or {}
    local_state = input_data.local_state or {}

    # Check if OpenResty is running
    openresty_running, openresty_error = is_openresty_running()
    if not openresty_running:
        if openresty_error and 'Failed to' in openresty_error:
            # Real error checking status
            return PluginOutput(status='error', error_message=openresty_error, local_state=local_state)
        else:
            # Service not running yet
            return PluginOutput(
                status='postponed',
                error_message=openresty_error or 'OpenResty service is not running',
                local_state=local_state
            )

    # Check if Redis hosts changed
    if isinstance(state_json, dict):
        current_redis_hosts = get_redis_tunnel_ips(state_json)
        previous_redis_hosts = local_state.get("redis_hosts", [])

        if sorted(current_redis_hosts) != sorted(previous_redis_hosts):
            print(f"[*] Redis hosts changed, will be updated on next apply", file=sys.stderr)
            # Don't fail health check, just log that config needs update
            # The next apply will handle the update

    # If this is the leader node, check if DNS records were successfully updated
    leader_node_id = get_leader_node(state_json)
    is_leader = (leader_node_id == local_node_id)

    print(f"[DEBUG] Health check: is_leader={is_leader}, leader_node_id={leader_node_id}, local_node_id={local_node_id}", file=sys.stderr)

    if is_leader:
        # Check if DNS update was successful (should be marked by apply)
        openresty_props = state_json.get("openrestyNodeProperties", [])
        dns_updated = False

        print(f"[DEBUG] Checking openresty_dns_updated property in {len(openresty_props)} properties", file=sys.stderr)

        for prop in openresty_props:
            if prop.get("node_id") == local_node_id:
                print(f"[DEBUG] Found property for local node: {prop.get('name')}={prop.get('value')}", file=sys.stderr)
            if (prop.get("node_id") == local_node_id and
                prop.get("name") == "openresty_dns_updated" and
                prop.get("value") == "true"):
                dns_updated = True
                break

        if not dns_updated:
            # DNS records haven't been updated yet
            global_id = state_json.get("globalId")
            base_domain = get_secret_from_swarmdb(state_json, "base_domain")

            print(f"[DEBUG] DNS update flag not set: global_id={global_id}, base_domain={base_domain}", file=sys.stderr)

            if global_id and base_domain:
                print(f"[!] Gateway DNS records not yet updated, waiting for apply", file=sys.stderr)
                return PluginOutput(
                    status='postponed',
                    error_message='Gateway DNS records not yet updated',
                    local_state=local_state
                )
        else:
            print(f"[*] Gateway DNS records are up-to-date", file=sys.stderr)

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('finalize')
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize before node removal (graceful shutdown)."""
    local_state = input_data.local_state or {}

    # TODO: Implement graceful shutdown if needed
    # This could involve:
    # - Draining connections
    # - Waiting for active requests to complete

    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy OpenResty installation and clean up."""
    try:
        # Stop and disable OpenResty
        subprocess.run(
            ["systemctl", "stop", "openresty"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        subprocess.run(
            ["systemctl", "disable", "openresty"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        # Remove config file
        if OPENRESTY_CONFIG_FILE.exists():
            OPENRESTY_CONFIG_FILE.unlink()

        # Remove SSL directory
        if OPENRESTY_SSL_DIR.exists():
            shutil.rmtree(OPENRESTY_SSL_DIR, ignore_errors=True)

        # Request deletion of node properties
        node_properties = {
            "openresty_ready": None,
        }

        return PluginOutput(
            status='completed',
            node_properties=node_properties,
            local_state={}
        )
    except Exception as e:
        return PluginOutput(
            status='error',
            error_message=f'Failed to destroy OpenResty: {e}',
            local_state={}
        )


if __name__ == "__main__":
    plugin.run()
