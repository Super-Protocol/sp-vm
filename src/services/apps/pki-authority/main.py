#!/usr/bin/env python3
"""PKI Authority service provisioning plugin."""

import base64
import hashlib
import json
import sys
import time
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput
from redis import RedisCluster
from redis.cluster import ClusterNode

# Import helpers
sys.path.insert(0, str(Path(__file__).parent))
from helpers import (
    delete_iptables_rules,
    detect_cpu_type,
    detect_vm_mode,
    detect_network_type,
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
    get_pki_authority_param,
    read_yaml_config_param,
)

# Configuration
plugin = ProvisionPlugin()


class EventHandler:
    """Handler for PKI Authority provisioning events."""

    # Authority service property prefix and names
    AUTHORITY_SERVICE_PREFIX = "pki_authority_"
    AUTHORITY_SERVICE_PROPERTIES = [
        "auth_token", "basic_certificate", "basic_privateKey",
        "lite_certificate", "lite_privateKey"
    ]
    PROP_INITIALIZED = f"{AUTHORITY_SERVICE_PREFIX}initialized"
    PROP_PKI_DOMAIN = f"{AUTHORITY_SERVICE_PREFIX}pki_domain"
    PROP_NETWORK_KEY_HASH = f"{AUTHORITY_SERVICE_PREFIX}network_key_hash"
    PROP_NETWORK_TYPE = f"{AUTHORITY_SERVICE_PREFIX}network_type"

    def __init__(self, input_data: PluginInput):
        self.input_data = input_data
        self.local_node_id = input_data.local_node_id
        self.state_json = input_data.state or {}
        self.local_state = input_data.local_state or {}
        self.cluster_info = self.state_json.get("cluster", {})
        leader_node_id = self.cluster_info.get("leader_node")
        self.is_leader = self.local_node_id == leader_node_id
        self.pki_cluster_nodes = self.state_json.get("clusterNodes", [])
        self.wg_props = self.state_json.get("wgNodeProperties", [])
        self.authority_props = self.state_json.get("authorityServiceProperties", [])
        self.authority_config = {prop["name"]: prop["value"] for prop in self.authority_props}

        self.pki_domain = self.authority_config.get(self.PROP_PKI_DOMAIN, "")
        self.network_key_hash = self.authority_config.get(self.PROP_NETWORK_KEY_HASH, "")
        self.network_type = self.authority_config.get(self.PROP_NETWORK_TYPE, "")
        self.initialized = self.authority_config.get(self.PROP_INITIALIZED, "")
        self.vm_mode = detect_vm_mode()

        # Read current pki_node_ready value
        pki_node_props = self.state_json.get("pkiNodeProperties", [])
        self.current_pki_node_ready = None
        for prop in pki_node_props:
            if prop.get("node_id") == self.local_node_id and prop.get("name") == "pki_node_ready":
                self.current_pki_node_ready = prop.get("value")
                break

        # Output parameters
        self.status = None
        self.error_message = None
        self.cluster_properties = {}
        self.node_properties = {}

    def _get_redis_tunnel_ips(self) -> list[str]:
        """Get list of Redis node tunnel IPs."""
        redis_node_props = self.state_json.get("redisNodeProperties", [])

        redis_hosts = []
        for prop in redis_node_props:
            if prop.get("name") == "redis_node_ready" and prop.get("value") == "true":
                node_id = prop.get("node_id")
                tunnel_ip = get_node_tunnel_ip(node_id, self.wg_props)
                if tunnel_ip:
                    redis_hosts.append(tunnel_ip)

        return sorted(set(redis_hosts))

    def _get_redis_connection_info(self) -> list[tuple[str, int]]:
        """Get Redis cluster connection endpoints.

        Returns list of (host, port) tuples for Redis nodes.
        """
        redis_tunnel_ips = self._get_redis_tunnel_ips()
        return [(ip, 6379) for ip in redis_tunnel_ips]

    def _get_current_endpoints(self) -> list[str]:
        """Get list of tunnel IPs for PKI nodes that are ready.

        Returns list of tunnel IPs for nodes with pki_node_ready=true.
        """
        pki_node_props = self.state_json.get("pkiNodeProperties", [])
        current_endpoints = []

        for cluster_node in self.pki_cluster_nodes:
            node_id = cluster_node.get("node_id")
            if not node_id:
                continue

            # Find pki_node_ready property for this node
            node_ready = False
            for prop in pki_node_props:
                if (prop.get("node_id") == node_id and
                    prop.get("name") == "pki_node_ready" and
                    prop.get("value") == "true"):
                    node_ready = True
                    break

            if node_ready:
                tunnel_ip = get_node_tunnel_ip(node_id, self.wg_props)
                if tunnel_ip:
                    current_endpoints.append(tunnel_ip)

        return current_endpoints

    def _create_gateway_endpoints(self):
        """Create and update gateway endpoints in Redis."""
        current_endpoints = self._get_current_endpoints()

        # Get Redis connection info
        redis_endpoints = self._get_redis_connection_info()

        if not redis_endpoints:
            self.status = "postponed"
            self.error_message = "No Redis nodes available to configure gateway routes"
            return

        route_key = f"manual-routes:{self.pki_domain}"
        startup_nodes = [ClusterNode(host, port) for host, port in redis_endpoints]

        try:
            redis_client = RedisCluster(
                startup_nodes=startup_nodes,
                decode_responses=True,
                skip_full_coverage_check=True,
                socket_connect_timeout=5,
            )

            # Read current route from Redis
            registered_endpoints = []
            existing_route = redis_client.get(route_key)
            if existing_route:
                route_data = json.loads(existing_route)
                # Extract IPs from targets URLs
                for target in route_data.get("targets", []):
                    url = target.get("url", "")
                    # Parse https://IP:PORT format
                    if "://" in url:
                        ip_port = url.split("://")[1]
                        ip = ip_port.split(":")[0]
                        registered_endpoints.append(ip)

            # Compare endpoints regardless of order
            if set(registered_endpoints) == set(current_endpoints):
                log(
                    LogLevel.INFO,
                    f"Gateway endpoints are up to date: "
                    f"registered={registered_endpoints}, current={current_endpoints}"
                )
                return

            log(
                LogLevel.INFO,
                f"Gateway endpoints changed: "
                f"registered={registered_endpoints}, current={current_endpoints}"
            )

            # Build targets list from current endpoints
            targets = [
                {"url": f"https://{endpoint}:8443", "weight": 1}
                for endpoint in current_endpoints
            ]
            route_config = {
                "targets": targets,
                "policy": "rr",
                "preserve_host": False,
                "passthrough": True
            }
            route_json = json.dumps(route_config)

            # Retry logic for setting route in Redis
            max_retries = 3
            retry_delay = 5

            for attempt in range(1, max_retries + 1):
                try:
                    redis_client.set(route_key, route_json)
                    log(
                        LogLevel.INFO,
                        f"Successfully set gateway route {route_key} in Redis Cluster"
                    )
                    break  # Success, exit retry loop
                except Exception as set_error:  # pylint: disable=broad-exception-caught
                    if attempt < max_retries:
                        log(
                            LogLevel.WARN,
                            f"Failed to set route (attempt {attempt}/{max_retries}): {set_error}. "
                            f"Retrying in {retry_delay}s..."
                        )
                        time.sleep(retry_delay)
                    else:
                        log(
                            LogLevel.ERROR,
                            f"Failed to set route after {max_retries} attempts: {set_error}"
                        )
                        raise

        except Exception as error:  # pylint: disable=broad-exception-caught
            error_msg = f"Failed to set route in Redis Cluster: {str(error)}"
            self.status = "postponed"
            self.error_message = error_msg
            log(LogLevel.ERROR, error_msg)

    def _create_output(self) -> PluginOutput:
        """Create plugin output based on current status."""
        if self.status == "completed":
            if self.is_leader:
                self._create_gateway_endpoints()
        elif self.status == "postponed":
            log(LogLevel.INFO, f"Apply postponed: {self.error_message}")
        elif self.status == "error":
            log(LogLevel.ERROR, f"Apply error: {self.error_message}")
        else:
            log(LogLevel.ERROR, f"Apply ended with unknown status {self.status}")

        # Determine if cluster_properties should be included
        should_update_cluster = (
            self.vm_mode == VMMode.SWARM_INIT or self.is_leader
        ) and self.status in ("completed", "postponed") and self.cluster_properties

        return PluginOutput(
            status=self.status,
            local_state=self.local_state if self.status == "completed" else None,
            error_message=self.error_message,
            cluster_properties=self.cluster_properties if should_update_cluster else None,
            node_properties=self.node_properties if self.node_properties else None
        )

    def apply(self) -> PluginOutput:
        """Apply PKI Authority configuration."""
        try:
            # Basic validation
            if not isinstance(self.state_json, dict):
                self.status = "error"
                self.error_message = "Invalid state format"
                return self._create_output()

            local_tunnel_ip = get_node_tunnel_ip(self.local_node_id, self.wg_props)
            if not local_tunnel_ip:
                self.status = "postponed"
                self.error_message = "Waiting for WireGuard tunnel IP to be configured"
                return self._create_output()

            if self.vm_mode == VMMode.SWARM_INIT:
                self._handle_swarm_init(local_tunnel_ip)
            else:
                self._handle_swarm_normal(local_tunnel_ip)

        except Exception as error:  # pylint: disable=broad-exception-caught
            error_msg = f"Apply failed: {str(error)}"
            log(LogLevel.ERROR, error_msg)
            self.status = "error"
            self.error_message = error_msg

        return self._create_output()

    def _stop_container_if_running(self, container: LXCContainer) -> None:
        """Stop container if it's running."""
        if container.is_running():
            log(LogLevel.INFO, "Stopping existing container")
            exit_code = container.stop(graceful_timeout=30, command_timeout=60)
            if exit_code != 0:
                raise Exception(f"Failed to stop container with exit code {exit_code}")

    def _ensure_container_running(self, container: LXCContainer, local_tunnel_ip: str) -> None:
        """Ensure container is running with correct configuration.

        Checks for missing properties, restart requirements,
        restores properties and starts container.
        Sets self.status to 'completed' or 'error' and self.error_message on error.
        """
        # Verify ALL required properties are present
        missing = self._check_for_missing_properties()

        if missing:
            error_msg = (
                f"Service marked as initialized but missing required properties: "
                f"{', '.join(missing)}"
            )
            log(LogLevel.ERROR, error_msg)
            self.status = "error"
            self.error_message = error_msg
            return

        # Check if restart is needed
        if container.is_running():
            if self._is_restart_required():
                log(LogLevel.INFO, "Configuration changed, restarting contain er")
                self._stop_container_if_running(container)
            else:
                # Everything matches, container running, nothing to do
                log(LogLevel.INFO, "Container running, no changes detected")
                self.status = "completed"
                return

        # Restore properties from DB to filesystem
        for prop in self.AUTHORITY_SERVICE_PROPERTIES:
            prop_name = f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"
            prop_value = self.authority_config.get(prop_name, "")
            save_property_into_fs(prop, base64.b64decode(prop_value))

        # Start container
        self._configure_and_start_container(container, local_tunnel_ip)
        self.status = "completed"

    def _configure_and_start_container(
        self, container: LXCContainer, local_tunnel_ip: str
    ) -> None:
        """Configure and start container."""
        cpu_type = detect_cpu_type()
        patch_yaml_config(
            cpu_type,
            self.vm_mode,
            self.pki_domain,
            self.network_type,
            self.network_key_hash
        )
        patch_lxc_config(cpu_type)
        update_pccs_url()
        setup_iptables(local_tunnel_ip)

        exit_code = container.start(timeout=30)
        if exit_code != 0:
            raise Exception(f"Failed to start container with exit code {exit_code}")

        is_healthy, err_msg = self.health(timeout=30, interval=5)
        if is_healthy:
            log(
                LogLevel.INFO,
                f"LXC container {PKI_SERVICE_NAME} started and health check passed"
            )
        else:
            log(
                LogLevel.WARN,
                f"LXC container {PKI_SERVICE_NAME} started but health check failed: {err_msg}"
            )

    def _check_for_missing_properties(self) -> list[str]:
        """Check for missing required properties.

        Returns:
            List of missing property names (empty if all present)
        """
        missing = []

        for prop in self.AUTHORITY_SERVICE_PROPERTIES:
            prop_name = f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"
            if not self.authority_config.get(prop_name, ""):
                missing.append(prop_name)

        if not self.pki_domain:
            missing.append(self.PROP_PKI_DOMAIN)

        if not self.network_key_hash:
            missing.append(self.PROP_NETWORK_KEY_HASH)

        if not self.network_type:
            missing.append(self.PROP_NETWORK_TYPE)

        return missing

    def _wait_for_properties_generation(self, timeout: int = 30, interval: int = 5) -> None:
        """Wait for tee-pki service to generate ALL property files."""
        missing_properties = self.AUTHORITY_SERVICE_PROPERTIES.copy()
        elapsed = 0
        collected_properties = {}

        while elapsed < timeout:
            # Try to read each missing property
            for prop in missing_properties[:]:
                success, value = read_property_from_fs(prop)

                if success:
                    prop_key = f"{self.AUTHORITY_SERVICE_PREFIX}{prop}"
                    collected_properties[prop_key] = base64.b64encode(value).decode()
                    missing_properties.remove(prop)

            # Check if ALL properties collected
            if not missing_properties:
                log(
                    LogLevel.INFO,
                    "All property files have been generated by tee-pki service"
                )
                # Set initialized flag ONLY when all properties are ready
                collected_properties[self.PROP_PKI_DOMAIN] = self.pki_domain
                collected_properties[self.PROP_NETWORK_KEY_HASH] = self.network_key_hash
                collected_properties[self.PROP_NETWORK_TYPE] = self.network_type
                collected_properties[self.PROP_INITIALIZED] = "true"
                self.initialized = "true"

                self.status = "completed"
                self.cluster_properties = collected_properties
                return

            log(
                LogLevel.INFO,
                f"Waiting for property files. Missing: "
                f"{', '.join(missing_properties)} (elapsed: {elapsed}s)"
            )

            time.sleep(interval)
            elapsed += interval

        # Timeout - NOT all properties collected, do NOT set initialized flag
        self.status = "postponed"
        self.error_message = (
            f"Timeout waiting for tee-pki to generate property files: "
            f"{', '.join(missing_properties)}"
        )

    def _handle_swarm_init(self, local_tunnel_ip: str) -> None:
        """Handle swarm-init mode: read external sources and initialize properties."""
        # Get pki_domain from external source (file)
        if not self.pki_domain:
            try:
                self.pki_domain = get_pki_authority_param("domain")
                log(LogLevel.INFO, f"Read PKI domain from external source: {self.pki_domain}")
            except Exception as error:  # pylint: disable=broad-exception-caught
                error_msg = f"Failed to get PKI domain from external source: {error}"
                log(LogLevel.ERROR, error_msg)
                self.status = "error"
                self.error_message = error_msg
                return

        # Get network_key_hash from external source (file)
        if not self.network_key_hash:
            try:
                network_key = get_pki_authority_param("networkKey")
                self.network_key_hash = hashlib.sha256(network_key.encode()).hexdigest()
                log(
                    LogLevel.INFO,
                    f"Calculated network key hash from external source: {self.network_key_hash}"
                )
            except Exception as error:  # pylint: disable=broad-exception-caught
                error_msg = f"Failed to get network key hash from external source: {error}"
                log(LogLevel.ERROR, error_msg)
                self.status = "error"
                self.error_message = error_msg
                return

        # Get network_type from kernel cmdline
        if not self.network_type:
            self.network_type = detect_network_type()
            log(LogLevel.INFO, f"Detected network type: {self.network_type}")

        container = LXCContainer(PKI_SERVICE_NAME)

        if self.initialized == "true":
            # Use common logic for ensuring container is running
            self._ensure_container_running(container, local_tunnel_ip)
            return

        # Not initialized - restart container and wait for properties generation
        log(LogLevel.INFO, "Service not initialized, starting initialization process")

        # Restart container if running
        if container.is_running():
            log(LogLevel.INFO, "Stopping container for initialization")
            self._stop_container_if_running(container)

        # Start container
        self._configure_and_start_container(container, local_tunnel_ip)
        # Wait for properties generation
        self._wait_for_properties_generation(timeout=30, interval=5)


    def _handle_swarm_normal(self, local_tunnel_ip: str) -> None:
        """Handle swarm-normal mode: read ONLY from properties (DB), no external sources."""
        # If not initialized - wait for swarm-init to complete
        if self.initialized != "true":
            self.status = "postponed"
            self.error_message = "Waiting for authority service properties to be initialized"
            return

        # All properties present - manage container
        container = LXCContainer(PKI_SERVICE_NAME)

        # Use common logic for ensuring container is running
        self._ensure_container_running(container, local_tunnel_ip)

    def _is_restart_required(self) -> bool:
        """Check if container restart is required based on config changes."""
        # Check file-based properties
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
            except Exception as error:  # pylint: disable=broad-exception-caught
                log(LogLevel.ERROR, f"Failed to decode property {prop}: {error}")
                return True

        # Check yaml config parameters
        yaml_params = [
            ("pki.ownDomain", self.pki_domain, "domain"),
            (
                "pki.mode.networkSettings.networkType",
                self.network_type,
                "network_type"
            ),
            (
                "pki.mode.networkSettings.networkKeyHashHex",
                self.network_key_hash,
                "network_key_hash"
            ),
        ]

        for yaml_path, expected_value, param_name in yaml_params:
            if not expected_value:
                continue

            yaml_value = read_yaml_config_param(yaml_path)

            if yaml_value != expected_value:
                log(
                    LogLevel.INFO,
                    f"Parameter {param_name} changed "
                    f"(yaml: {yaml_value}, expected: {expected_value}), restart required"
                )
                return True

        # No changes detected
        log(LogLevel.INFO, "No configuration changes detected")
        return False

    def _delete_route_from_redis(self) -> None:
        """Delete the PKI Authority route from Redis Cluster.

        Raises:
            Exception: If deletion fails
        """
        redis_endpoints = self._get_redis_connection_info()

        if not redis_endpoints:
            log(LogLevel.WARN, "No Redis endpoints available, skipping route deletion")
            return

        route_key = f"routes:{self.pki_domain}"
        startup_nodes = [ClusterNode(host, port) for host, port in redis_endpoints]

        redis_client = RedisCluster(
            startup_nodes=startup_nodes,
            decode_responses=True,
            skip_full_coverage_check=True,
            socket_connect_timeout=5,
        )
        redis_client.delete(route_key)
        log(LogLevel.INFO, f"Deleted route {route_key} from Redis Cluster")

    def destroy(self) -> PluginOutput:
        """Destroy PKI Authority service and clean up."""
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
                return PluginOutput(
                    status="error",
                    error_message=error_msg,
                    local_state=self.local_state
                )

            delete_iptables_rules()

            # If this is the last node and domain is configured, delete route from Redis
            if len(self.pki_cluster_nodes) <= 1 and self.pki_domain:
                log(
                    LogLevel.INFO,
                    "This is the last PKI Authority node, deleting route from Redis"
                )
                self._delete_route_from_redis()

            log(LogLevel.INFO, "PKI Authority destroyed")
            return PluginOutput(
                status="completed",
                local_state=self.local_state,
                cluster_properties=(
                    self.cluster_properties if self.cluster_properties else None
                )
            )

        except Exception as error:  # pylint: disable=broad-exception-caught
            error_msg = f"Destroy failed: {str(error)}"
            log(LogLevel.ERROR, error_msg)
            return PluginOutput(
                status="error", error_message=error_msg, local_state=self.local_state
            )

    def health(self, timeout: int = 0, interval: int = 5) -> tuple[bool, str]:
        """Check health of PKI Authority service.

        Args:
            timeout: Maximum time to wait for service to become healthy (0 = single check)
            interval: Time between health check attempts

        Returns:
            Tuple of (is_healthy, error_message). If healthy, error_message is empty string.
        """
        is_healthy = False
        error_msg = ""

        try:
            container = LXCContainer(PKI_SERVICE_NAME)
            elapsed = 0
            attempt = 0

            while True:
                attempt += 1
                if container.is_running() and container.is_service_healthy():
                    is_healthy = True
                    break

                # If timeout is 0, only check once
                if timeout == 0 or elapsed >= timeout:
                    error_msg = (
                        f"PKI service is not healthy or container is not running "
                        f"(attempts: {attempt})"
                    )
                    break

                # Wait before next attempt
                time.sleep(interval)
                elapsed += interval

        except Exception as error:  # pylint: disable=broad-exception-caught
            error_msg = f"Health check failed on attempt {attempt}: {str(error)}"
            log(LogLevel.ERROR, error_msg)

        # Compare current pki_node_ready with new health status
        current_healthy_status = "true" if is_healthy else "false"
        if self.current_pki_node_ready != current_healthy_status:
            log(
                LogLevel.INFO,
                f"PKI node ready status changed: "
                f"{self.current_pki_node_ready} -> {current_healthy_status}"
            )
            self.node_properties["pki_node_ready"] = current_healthy_status

        return (is_healthy, error_msg)


# Plugin commands
@plugin.command("init")
def handle_init(input_data: PluginInput) -> PluginOutput:
    """Initialize PKI Authority service."""
    try:
        log(LogLevel.INFO, "Running PKI initialization")
        init_container()
        log(LogLevel.INFO, "PKI initialization completed")
        return PluginOutput(status="completed", local_state=input_data.local_state)
    except Exception as error:  # pylint: disable=broad-exception-caught
        error_msg = f"Failed to initialize PKI: {str(error)}"
        log(LogLevel.ERROR, error_msg)
        return PluginOutput(
            status="error", error_message=error_msg, local_state=input_data.local_state
        )


@plugin.command("apply")
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Apply PKI Authority configuration and start service."""
    handler = EventHandler(input_data)
    return handler.apply()


@plugin.command("health")
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Check health of PKI Authority service."""
    handler = EventHandler(input_data)
    is_healthy, error_msg = handler.health()

    if is_healthy:
        return PluginOutput(
            status="completed",
            local_state=input_data.local_state,
            node_properties=handler.node_properties if handler.node_properties else None
        )

    return PluginOutput(
        status="error",
        error_message=error_msg,
        local_state=input_data.local_state,
        node_properties=handler.node_properties if handler.node_properties else None
    )


@plugin.command("finalize")
def handle_finalize(input_data: PluginInput) -> PluginOutput:
    """Finalize PKI Authority service setup."""
    log(LogLevel.INFO, "PKI Authority finalized")
    return PluginOutput(status="completed", local_state=input_data.local_state)


@plugin.command("destroy")
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Destroy PKI Authority service and clean up."""
    handler = EventHandler(input_data)
    return handler.destroy()


if __name__ == "__main__":
    plugin.run()
