#!/usr/bin/env python3

import sys
import time
import json
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput
import base64
from redis import RedisCluster
from redis.cluster import ClusterNode

# Import helpers
sys.path.insert(0, str(Path(__file__).parent))
from helpers import (
    delete_iptables_rules,
    detect_cpu_type,
    detect_vm_mode,
    patch_yaml_config,
    patch_lxc_config,
    setup_iptables,
    update_pccs_url,
    LXCContainer,
    PKI_SERVICE_NAME,
    get_node_tunnel_ip,
    init_container,
    VMMode,
    save_property_into_fs,
    read_property_from_fs,
    LogLevel,
    log,
    get_pki_domain,
)

# Configuration
plugin = ProvisionPlugin()


class ApplyHandler:
    """Handler for apply command logic with unified exit point."""
    
    # Authority service property prefix and names
    AUTHORITY_SERVICE_PREFIX = "pki_authority_"
    AUTHORITY_SERVICE_PROPERTIES = ["auth_token", "basic_certificate", "basic_privateKey", "lite_certificate", "lite_privateKey"]
    PROP_INITIALIZED = f"{AUTHORITY_SERVICE_PREFIX}initialized"
    PROP_REGISTERED_ENDPOINTS = f"{AUTHORITY_SERVICE_PREFIX}registered_endpoints"
    PROP_PKI_DOMAIN = f"{AUTHORITY_SERVICE_PREFIX}pki_domain"
    
    def __init__(self, input_data: PluginInput):
        self.input_data = input_data
        self.local_node_id = input_data.local_node_id
        self.state_json = input_data.state or {}
        self.local_state = input_data.local_state or {}
        self.cluster_info = self.state_json.get("cluster", {})
        leader_node_id = self.cluster_info.get("leader_node")
        self.is_leader = (self.local_node_id == leader_node_id)
        self.pki_cluster_nodes = self.state_json.get("clusterNodes", [])
        self.wg_props = self.state_json.get("wgNodeProperties", [])
        self.authority_props = self.state_json.get("authorityServiceProperties", [])
        self.authority_config = {prop["name"]: prop["value"] for prop in self.authority_props}
        
        self.pki_domain = self.authority_config.get(self.PROP_PKI_DOMAIN, "")
        
        # Output parameters
        self.status = None
        self.error_message = None
        self.cluster_properties = {}
    
    def get_redis_tunnel_ips(self) -> list[str]:
        """Get list of Redis node tunnel IPs."""
        redis_node_props = self.state_json.get("redisNodeProperties", [])
        wg_props = self.state_json.get("wgNodeProperties", [])

        redis_hosts = []
        for prop in redis_node_props:
            if prop.get("name") == "redis_node_ready" and prop.get("value") == "true":
                node_id = prop.get("node_id")
                tunnel_ip = get_node_tunnel_ip(node_id, wg_props)
                if tunnel_ip:
                    redis_hosts.append(tunnel_ip)

        return sorted(set(redis_hosts))
    
    def get_redis_connection_info(self) -> list[tuple[str, int]]:
        """Get Redis cluster connection endpoints.
        
        Returns list of (host, port) tuples for Redis nodes.
        """
        redis_tunnel_ips = self.get_redis_tunnel_ips()
        return [(ip, 6379) for ip in redis_tunnel_ips]
    
    
    def create_gateway_endpoints(self):
        if not self.is_leader:
            return
        
        registered_endpoints = self.authority_config.get(self.PROP_REGISTERED_ENDPOINTS, "").split(";")
        
        current_endpoints = []
        for node in self.pki_cluster_nodes:
            node_id = node.get("node_id")
            tunnel_ip = get_node_tunnel_ip(node_id, self.wg_props)
            if tunnel_ip:
                current_endpoints.append(tunnel_ip)
        
        # Compare endpoints regardless of order
        if set(registered_endpoints) == set(current_endpoints):
            log(LogLevel.INFO, f"Gateway endpoints are up to date: registered={registered_endpoints}, current={current_endpoints}")
            return
        
        log(LogLevel.INFO, f"Gateway endpoints changed: registered={registered_endpoints}, current={current_endpoints}")
        
        # Get Redis connection info
        redis_endpoints = self.get_redis_connection_info()
        
        if not redis_endpoints and current_endpoints:
            self.status = "postponed"
            self.error_message = "No Redis nodes available to configure gateway routes"
            return
        
        # Build targets list from current endpoints
        targets = [{"url": f"https://{endpoint}:8443", "weight": 1} for endpoint in current_endpoints]
        route_config = {
            "targets": targets,
            "policy": "rr",
            "preserve_host": False,
            "passthrough": True
        }
        route_json = json.dumps(route_config)
        route_key = f"routes:{self.pki_domain}"
        
        startup_nodes = [ClusterNode(host, port) for host, port in redis_endpoints]
        
        try:
            redis_client = RedisCluster(
                startup_nodes=startup_nodes,
                decode_responses=True,
                skip_full_coverage_check=True,
                socket_connect_timeout=5,
            )
            redis_client.ping()
            
            redis_client.set(route_key, route_json)
            log(LogLevel.INFO, f"Successfully set gateway route {route_key} in Redis Cluster")
            
            if self.cluster_properties is None:
                self.cluster_properties = {}
            self.cluster_properties[self.PROP_REGISTERED_ENDPOINTS] = ";".join(current_endpoints)
            
        except Exception as e:
            error_msg = f"Failed to set route in Redis Cluster: {str(e)}"
            self.status = "error"
            self.error_message = error_msg
            log(LogLevel.ERROR, error_msg)

    def create_output(self) -> PluginOutput:
        if self.status == "completed":
            self.create_gateway_endpoints()
        elif self.status =="postponed":
            log(LogLevel.INFO, f"Apply postponed: {self.error_message}")
        elif self.status == "error":
            log(LogLevel.ERROR, f"Apply error: {self.error_message}")
        else:
            log(LogLevel.ERROR, f"Apply ended with unknown status {self.status}")

        return PluginOutput(
            status=self.status,
            local_state=self.local_state if self.status == "completed" else None,
            error_message=self.error_message,
            cluster_properties=self.cluster_properties if self.status == "completed" else None
        )
    
    def apply(self) -> PluginOutput:
        if not isinstance(self.state_json, dict):
            self.status = "error"
            self.error_message = "Invalid state format"
            return self.create_output()
        
        local_tunnel_ip = get_node_tunnel_ip(self.local_node_id, self.wg_props)
        if not local_tunnel_ip:
            self.status = "error"
            self.error_message = "Local node has no WireGuard tunnel IP"
            return self.create_output()
        
        try:
            vm_mode = detect_vm_mode()
            initialized = self.authority_config.get(self.PROP_INITIALIZED)
            
            # If initialized is true, verify all required properties are present
            if initialized == "true":
                missing = []
                
                for prop in self.AUTHORITY_SERVICE_PROPERTIES:
                    prop_name = f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"
                    prop_value = self.authority_config.get(prop_name, "")
                    
                    if not prop_value:
                        missing.append(prop_name)
                
                if not self.pki_domain:
                    self.pki_domain = get_pki_domain()
                    missing.append(self.PROP_PKI_DOMAIN)

                if missing:
                    error_msg = f"Service marked as initialized but missing properties: {', '.join(missing)}"
                    log(LogLevel.ERROR, error_msg)
                    initialized = "false"
            
            if vm_mode == VMMode.SWARM_NORMAL and initialized != "true":
                self.status = "postponed"
                self.error_message = "Waiting for authority service properties to be initialized"
                return self.create_output()

            container = LXCContainer(PKI_SERVICE_NAME)
            
            # Start or restart LXC container
            if container.is_running():
                if initialized != "true" or self.is_restart_required():
                    exit_code = container.stop(graceful_timeout=30, command_timeout=60)
                    if exit_code != 0:
                        raise Exception(f"Failed to stop container with exit code {exit_code}")
                else:
                    log(LogLevel.INFO, f"Container {PKI_SERVICE_NAME} is already running, no restart required")
                    self.status = "completed"
                    return self.create_output()
            
            cpu_type = detect_cpu_type()
            if not self.pki_domain:
                self.pki_domain = get_pki_domain()
            patch_yaml_config(cpu_type, vm_mode, self.pki_domain)
            patch_lxc_config(cpu_type)
            update_pccs_url()
            setup_iptables(local_tunnel_ip)

            if initialized == "true":
                for prop in self.AUTHORITY_SERVICE_PROPERTIES:
                    prop_name = f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"
                    prop_value = self.authority_config.get(prop_name, "")
                    save_property_into_fs(prop, base64.b64decode(prop_value))

            exit_code = container.start(timeout=30)
            if exit_code != 0:
                raise Exception(f"Failed to start container with exit code {exit_code}")

            log(LogLevel.INFO, f"LXC container {PKI_SERVICE_NAME} is running")

            # If not initialized, wait for tee-pki service to generate property files
            if initialized != "true":
                missing_properties = self.AUTHORITY_SERVICE_PROPERTIES.copy()
                timeout = 30
                interval = 5
                elapsed = 0
                collected_properties = {}
                
                while elapsed < timeout:
                    # Try to read each missing property
                    for prop in missing_properties[:]:
                        success, value = read_property_from_fs(prop)              
                        
                        if success:
                            collected_properties[f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"] = base64.b64encode(value).decode()
                            missing_properties.remove(prop)
                    
                    # Check if all properties collected
                    if not missing_properties:
                        log(LogLevel.INFO, "All property files have been generated by tee-pki service")
                        collected_properties[self.PROP_PKI_DOMAIN] =  self.pki_domain
                        collected_properties[self.PROP_INITIALIZED] = "true"
                        
                        self.status = "completed"
                        self.cluster_properties = collected_properties
                        return self.create_output()
                    
                    # Show what's still missing
                    log(LogLevel.INFO, f"Waiting for property files. Missing: {', '.join(missing_properties)} (elapsed: {elapsed}s)")
                    
                    time.sleep(interval)
                    elapsed += interval
                
                # Timeout reached
                self.status = "postponed"
                self.error_message = f"Timeout waiting for tee-pki to generate property files: {', '.join(missing_properties)}"
                return self.create_output()
            
            self.status = "completed"
            return self.create_output()
            
        except Exception as e:
            error_msg = f"Apply failed: {str(e)}"
            log(LogLevel.ERROR, error_msg)
            self.status = "error"
            self.error_message = error_msg
            return self.create_output()
    
    def is_restart_required(self) -> bool:
        """Check if container restart is required based on configuration changes."""
        for prop in self.AUTHORITY_SERVICE_PROPERTIES:
            prop_name = f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"
            config_value = self.authority_config.get(prop_name, "")
            
            if not config_value:
                continue
                
            # Read current value from filesystem
            success, fs_value = read_property_from_fs(prop)
            
            if not success:
                # File doesn't exist in FS, restart required
                log(LogLevel.INFO, f"Property {prop} not found in filesystem, restart required")
                return True
            
            # Decode config value from base64 and compare with filesystem value
            try:
                decoded_config_value = base64.b64decode(config_value)
                if decoded_config_value != fs_value:
                    log(LogLevel.INFO, f"Property {prop} has changed, restart required")
                    return True
            except Exception as e:
                log(LogLevel.ERROR, f"Failed to decode property {prop}: {e}")
                return True
        
        # No changes detected
        log(LogLevel.INFO, "No configuration changes detected")
        return False


# Plugin commands
@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize PKI Authority service."""
    try:
        log(LogLevel.INFO, "Running PKI initialization")
        init_container()
        log(LogLevel.INFO, "PKI initialization completed")
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as e:
        error_msg = f"Failed to initialize PKI: {str(e)}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(status="error", error_message=error_msg, local_state=input_data.local_state)


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply PKI Authority configuration and start service."""
    handler = ApplyHandler(input_data)
    return handler.apply()


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check health of PKI Authority service."""
    local_state = input_data.local_state or {}

    try:
        container = LXCContainer(PKI_SERVICE_NAME)
        
        if container.is_running() and container.is_service_healthy():
            return PluginOutput(status="completed", local_state=local_state)
        else:
            return PluginOutput(
                status="error",
                error_message="PKI service is not healthy or container is not running",
                local_state=local_state
            )
    except Exception as e:
        error_msg = f"Health check failed: {str(e)}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize PKI Authority service setup."""
    log(LogLevel.INFO, "PKI Authority finalized")
    return PluginOutput(status="completed", local_state=input_data.local_state)


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy PKI Authority service and clean up."""
    local_state = input_data.local_state or {}

    try:
        container = LXCContainer(PKI_SERVICE_NAME)
        
        # Stop container if running
        if container.is_running():
            exit_code = container.stop(graceful_timeout=30, command_timeout=60)
            if exit_code != 0:
                log(LogLevel.WARN, "Failed to stop container gracefully")
        
        # Destroy container
        exit_code = container.destroy()
        if exit_code != 0:
            error_msg = f"Failed to destroy container with exit code {exit_code}"
            return PluginOutput(status="error", error_message=error_msg, local_state=local_state)
        
        delete_iptables_rules()

        log(LogLevel.INFO, "PKI Authority destroyed")
        return PluginOutput(status="completed", local_state=local_state)

    except Exception as e:
        error_msg = f"Destroy failed: {str(e)}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(status="error", error_message=error_msg, local_state=local_state)


if __name__ == "__main__":
    plugin.run()
