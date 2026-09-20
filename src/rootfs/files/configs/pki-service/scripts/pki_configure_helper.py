#!/usr/bin/env python3

import argparse
import ipaddress
import json
import secrets
import struct
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

import yaml

SWARM_KEY_FILE = "/etc/swarm/swarm.key"
SWARM_CPU_TYPE_FILE = "/etc/swarm/swarm-cpu-type"
SWARM_NETWORK_TYPE_FILE = "/etc/swarm/swarm-network-type"
SERVICE_NAME = "pki-configure-helper"
SYNC_CLIENT_PORT = 9443
IMDS_TIMEOUT_SEC = 0.5
AZURE_IMDS_COMPUTE_URL = (
    "http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01"
)
TDX_AZURE_TYPE = "tdx-azure"

# Hyper-V reports the TEE backing an isolated guest through its own CPUID
# leaves. This is what the kernel reads (hv_get_isolation_type()), and on Azure
# it is the only precise source: see hv_isolation_type() below.
CPUID_DEVICE = "/dev/cpu/0/cpuid"
HV_CPUID_INTERFACE = 0x40000000
HV_CPUID_ISOLATION_CONFIG = 0x4000000C
HV_SIGNATURE = b"Microsoft Hv"
HV_ISOLATION_TYPE_MASK = 0xF
HV_ISOLATION_TYPE_NONE = 0
HV_ISOLATION_TYPE_VBS = 1
HV_ISOLATION_TYPE_SNP = 2
HV_ISOLATION_TYPE_TDX = 3


class LiteralBlockDumper(yaml.SafeDumper):
    """Render multi-line strings using YAML literal block style."""


def _represent_multiline_str(dumper: yaml.SafeDumper, data: str):
    style = "|" if "\n" in data else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)


LiteralBlockDumper.add_representer(str, _represent_multiline_str)


def log(level: str, message: str):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{SERVICE_NAME}] [{level}] {message}", file=sys.stderr)


def dump_yaml(data: dict) -> str:
    return yaml.dump(
        data,
        Dumper=LiteralBlockDumper,
        sort_keys=False,
        allow_unicode=True,
    )


def read_first_line(path: Path) -> str | None:
    if not path.exists():
        return None

    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        return None

    return lines[0].strip() or None


def _imds_get(url: str, headers: dict[str, str]) -> str | None:
    request = Request(url, headers=headers, method="GET")
    try:
        with urlopen(request, timeout=IMDS_TIMEOUT_SEC) as response:
            body = response.read()
    except (URLError, TimeoutError, OSError):
        return None
    if not body:
        return None
    return body.decode("utf-8", errors="replace")


def _cpuinfo_flag_tokens() -> set[str]:
    path = Path("/proc/cpuinfo")
    if not path.exists():
        return set()
    tokens: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key, _, value = line.partition(":")
        if key.strip() in ("flags", "Features"):
            tokens.update(value.split())
    return tokens


def _cpuinfo_has_intel_tdx() -> bool:
    path = Path("/proc/cpuinfo")
    if not path.exists():
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    return "Intel TDX" in text


def _cpuid(leaf: int, subleaf: int = 0) -> tuple[int, int, int, int] | None:
    """Read one CPUID leaf through /dev/cpu/0/cpuid (needs CONFIG_X86_CPUID)."""
    try:
        with open(CPUID_DEVICE, "rb") as handle:
            handle.seek((subleaf << 32) | leaf)
            data = handle.read(16)
    except OSError:
        return None
    if len(data) != 16:
        return None
    return struct.unpack("<4I", data)


def hv_isolation_type() -> int | None:
    """Return the Hyper-V isolation type, or None when not a Hyper-V guest.

    Azure confidential VMs run behind a paravisor, so the guest is given none
    of the usual TEE interfaces: no /dev/tdx_guest, no TSM provider, no
    tdx_guest CPUID flag, no TDEL ACPI table, and CPUID leaf 0x21 reads back as
    zeroes. IMDS is no help either -- securityProfile only says
    "ConfidentialVM" and never names the TEE. What the hypervisor does report
    is its isolation type, which is exactly what the kernel itself uses to
    decide it is running under TDX.
    """
    regs = _cpuid(HV_CPUID_INTERFACE)
    if regs is None:
        return None
    max_leaf, ebx, ecx, edx = regs
    if struct.pack("<III", ebx, ecx, edx) != HV_SIGNATURE:
        return None
    if max_leaf < HV_CPUID_ISOLATION_CONFIG:
        return None
    regs = _cpuid(HV_CPUID_ISOLATION_CONFIG)
    if regs is None:
        return None
    return regs[1] & HV_ISOLATION_TYPE_MASK


def is_tdx_guest() -> bool:
    # When the hypervisor states the isolation type, it is authoritative: it
    # both confirms TDX and rules it out on an SEV-SNP guest.
    isolation = hv_isolation_type()
    if isolation is not None:
        return isolation == HV_ISOLATION_TYPE_TDX
    if Path("/dev/sev-guest").exists():
        return False
    flags = _cpuinfo_flag_tokens()
    if "tdx_guest" in flags:
        return True
    if Path("/sys/module/tdx_guest").exists():
        return True
    return _cpuinfo_has_intel_tdx()


def is_sev_snp_guest() -> bool:
    """Counterpart of is_tdx_guest() for AMD SEV-SNP.

    NOT verified on a live SEV-SNP guest: the isolation type is read exactly
    like the TDX one, but only the TDX value has been confirmed against real
    hardware so far.
    """
    isolation = hv_isolation_type()
    if isolation is not None:
        return isolation == HV_ISOLATION_TYPE_SNP
    return Path("/dev/sev-guest").exists()


def is_azure_confidential_vm() -> bool:
    body = _imds_get(AZURE_IMDS_COMPUTE_URL, {"Metadata": "true"})
    if body is None:
        return False
    try:
        compute = json.loads(body)
    except json.JSONDecodeError:
        return False
    if not isinstance(compute, dict):
        return False
    security = compute.get("securityProfile")
    if not isinstance(security, dict):
        return False
    security_type = str(security.get("securityType") or "").strip().lower()
    return security_type == "confidentialvm"


def try_detect_tdx_azure() -> bool:
    return is_azure_confidential_vm() and is_tdx_guest()


def ensure_cpu_type(cpu_type_path: Path = Path(SWARM_CPU_TYPE_FILE)) -> str:
    cpu_type = read_first_line(cpu_type_path)
    if cpu_type is not None:
        return cpu_type

    if try_detect_tdx_azure():
        cpu_type_path.parent.mkdir(parents=True, exist_ok=True)
        cpu_type_path.write_text(f"{TDX_AZURE_TYPE}\n", encoding="utf-8")
        log("INFO", f"Detected CPU type '{TDX_AZURE_TYPE}' and saved to {cpu_type_path}")
        return TDX_AZURE_TYPE

    subprocess.run(
        ["/usr/bin/pki-cert-generator", "get-attestation-type", "--output", str(cpu_type_path)],
        check=True,
    )
    cpu_type = read_first_line(cpu_type_path)
    if cpu_type is None:
        raise ValueError(f"CPU type file is missing or empty: {cpu_type_path}")
    return cpu_type


def detect_network_type() -> str:
    network_type_path = Path(SWARM_NETWORK_TYPE_FILE)

    network_type = read_first_line(network_type_path)
    if network_type is None:
        raise ValueError(f"Network type file is missing or empty: {network_type_path}")
    if network_type not in ("trusted", "untrusted"):
        raise ValueError(f"Invalid network type '{network_type}' in {network_type_path}")

    cpu_type = ensure_cpu_type()
    if network_type == "trusted" and cpu_type == "untrusted":
        raise ValueError("Network type 'trusted' is incompatible with CPU type 'untrusted'")

    return network_type


def patch_template(template: dict, network_type: str) -> dict:
    certificates = template.get("certificates")
    if not isinstance(certificates, list):
        raise ValueError("Invalid template: 'certificates' must be a list")

    for cert in certificates:
        if isinstance(cert, dict) and cert.get("certRole") == "root":
            cert["networkType"] = network_type

    return template


def has_non_empty_value(value, field_name: str, value_type: type) -> bool:
    if value is None:
        return False

    if value_type not in (list, str):
        raise ValueError(f"Unsupported value type '{value_type.__name__}' for field '{field_name}'")

    if not isinstance(value, value_type):
        type_name = "list" if value_type is list else "string"
        raise ValueError(f"Invalid config: '{field_name}' must be a {type_name} or null")

    if value_type is str:
        return value.strip() != ""

    return len(value) > 0


def detect_swarm_pki_state(config_data: dict) -> str:
    swarm_db = config_data.get("swarm_db") or {}
    if not isinstance(swarm_db, dict):
        raise ValueError("Invalid config: 'swarm_db' must be a mapping")

    pki_authority = config_data.get("pki_authority")
    pki_authority = pki_authority or {}
    if not isinstance(pki_authority, dict):
        raise ValueError("Invalid config: 'pki_authority' must be a mapping")

    has_join_addresses = has_non_empty_value(
        swarm_db.get("join_addresses"),
        "swarm_db.join_addresses",
        list,
    )
    has_ca_bundle = has_non_empty_value(
        pki_authority.get("caBundle"),
        "pki_authority.caBundle",
        str,
    )
    has_servers = has_non_empty_value(
        pki_authority.get("servers"),
        "pki_authority.servers",
        list,
    )

    if not has_join_addresses and not has_ca_bundle and not has_servers:
        return "init"

    if has_join_addresses and has_ca_bundle and has_servers:
        return "normal"

    raise ValueError(
        "Inconsistent /sp/swarm/config.yaml: 'swarm_db.join_addresses', "
        "'pki_authority.caBundle' and 'pki_authority.servers' must be either all empty "
        "or all non-empty"
    )


def ensure_mapping(value, field_name: str, *, allow_empty: bool = True) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"Invalid config: '{field_name}' must be a mapping")
    if not allow_empty and not value:
        raise ValueError(f"Invalid config: '{field_name}' must not be empty")
    return value


def read_string_list(value, field_name: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"Invalid config: '{field_name}' must be a list or null")

    result = []
    for index, item in enumerate(value):
        if not isinstance(item, str):
            raise ValueError(f"Invalid config: '{field_name}[{index}]' must be a string")

        stripped_item = item.strip()
        if not stripped_item:
            raise ValueError(f"Invalid config: '{field_name}[{index}]' must not be empty")
        result.append(stripped_item)

    return result


def extract_host_from_address(address: str, field_name: str) -> str:
    stripped_address = address.strip()
    if not stripped_address:
        raise ValueError(f"Invalid config: '{field_name}' must not contain empty values")

    if stripped_address.startswith("["):
        closing_bracket_index = stripped_address.find("]")
        if closing_bracket_index == -1:
            raise ValueError(
                f"Invalid value '{address}' in '{field_name}': missing closing bracket for IPv6 host"
            )

        host = stripped_address[1:closing_bracket_index].strip()
        if not host:
            raise ValueError(f"Invalid value '{address}' in '{field_name}': empty IPv6 host")

        suffix = stripped_address[closing_bracket_index + 1:]
        if suffix and not (suffix.startswith(":") and suffix[1:].isdigit()):
            raise ValueError(f"Invalid value '{address}' in '{field_name}': unexpected suffix '{suffix}'")

        return host

    try:
        ipaddress.IPv6Address(stripped_address)
        return stripped_address
    except ValueError:
        pass

    if ":" in stripped_address:
        host_candidate, port_candidate = stripped_address.rsplit(":", 1)
        if host_candidate and port_candidate.isdigit():
            return host_candidate

    return stripped_address


def normalize_join_address_for_sync_server(join_address: str) -> str:
    host = extract_host_from_address(join_address, "swarm_db.join_addresses")
    try:
        ipaddress.IPv6Address(host)
        return f"[{host}]:{SYNC_CLIENT_PORT}"
    except ValueError:
        return f"{host}:{SYNC_CLIENT_PORT}"


def build_sync_client_pki_authority(config_data: dict) -> dict:
    if not isinstance(config_data, dict):
        raise ValueError("Invalid config: root must be a mapping")

    swarm_db = ensure_mapping(config_data.get("swarm_db") or {}, "swarm_db")
    pki_authority = ensure_mapping(config_data.get("pki_authority"), "pki_authority", allow_empty=False)

    existing_servers = read_string_list(pki_authority.get("servers"), "pki_authority.servers")
    join_addresses = read_string_list(swarm_db.get("join_addresses"), "swarm_db.join_addresses")

    merged_servers = []
    seen_servers = set()
    seen_server_hosts = set()

    for server in existing_servers:
        if server in seen_servers:
            continue
        seen_servers.add(server)
        seen_server_hosts.add(extract_host_from_address(server, "pki_authority.servers"))
        merged_servers.append(server)

    for join_address in join_addresses:
        join_host = extract_host_from_address(join_address, "swarm_db.join_addresses")
        if join_host in seen_server_hosts:
            continue

        normalized_server = normalize_join_address_for_sync_server(join_address)
        if normalized_server in seen_servers:
            continue
        seen_servers.add(normalized_server)
        seen_server_hosts.add(join_host)
        merged_servers.append(normalized_server)

    rendered_pki_authority = dict(pki_authority)
    rendered_pki_authority["servers"] = merged_servers
    return {"pki_authority": rendered_pki_authority}


def run_get_vm_mode(config_path: Path, output_path: Path) -> int:
    if not config_path.exists():
        log("ERROR", f"Config file does not exist: {config_path}")
        return 255

    try:
        config_data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if not isinstance(config_data, dict):
            raise ValueError("Invalid config: root must be a mapping")

        vm_mode = detect_swarm_pki_state(config_data)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(f"{vm_mode}\n", encoding="utf-8")
        log("INFO", f"Detected vm-mode '{vm_mode}' and saved to {output_path}")
        try:
            cpu_type_path = Path(SWARM_CPU_TYPE_FILE)
            if read_first_line(cpu_type_path) is None and try_detect_tdx_azure():
                cpu_type_path.parent.mkdir(parents=True, exist_ok=True)
                cpu_type_path.write_text(f"{TDX_AZURE_TYPE}\n", encoding="utf-8")
                log("INFO", f"Detected CPU type '{TDX_AZURE_TYPE}' and saved to {cpu_type_path}")
        except Exception as error:
            log("WARN", f"Azure TDX detection skipped: {error}")
        return 0
    except Exception as error:
        log("ERROR", f"Failed to detect vm-mode from /sp/swarm/config.yaml: {error}")
        return 255


def run_configure(template_path: Path, output_path: Path):
    if not template_path.exists():
        log("ERROR", f"Template file does not exist: {template_path}")
        return 1

    try:
        generate_swarm_key()
        log("INFO", f"Loading template from {template_path}")
        template_data = yaml.safe_load(template_path.read_text(encoding="utf-8"))
        if not isinstance(template_data, dict):
            raise ValueError("Invalid template: root must be a mapping")

        network_type = detect_network_type()
        log("INFO", f"Detected networkType={network_type}")

        rendered_data = patch_template(template_data, network_type)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            dump_yaml(rendered_data),
            encoding="utf-8",
        )

        log("INFO", f"Rendered config saved to {output_path}")
        return 0
    except Exception as error:
        log("ERROR", f"Failed to render cert-gen config: {error}")
        return 1


def run_configure_sync_client(config_path: Path, output_path: Path) -> int:
    if not config_path.exists():
        log("ERROR", f"Config file does not exist: {config_path}")
        return 1

    try:
        log("INFO", f"Loading swarm config from {config_path}")
        config_data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        rendered_data = build_sync_client_pki_authority(config_data)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            dump_yaml(rendered_data),
            encoding="utf-8",
        )

        log("INFO", f"Rendered sync-client config saved to {output_path}")
        return 0
    except Exception as error:
        log("ERROR", f"Failed to render sync-client config: {error}")
        return 1



def generate_swarm_key(swarm_key_path: Path = Path(SWARM_KEY_FILE)) -> None:
    """Generate a 32-byte swarm key once and reuse it on subsequent runs."""

    if swarm_key_path.exists():
        log("INFO", f"Swarm key file already exists at {swarm_key_path}, skipping generation")
        return

    log("INFO", "Generating new 32-byte swarm key")
    swarm_key = secrets.token_hex(32)

    try:
        if not swarm_key_path.parent.exists():
            swarm_key_path.parent.mkdir(parents=True, exist_ok=True)
            log("INFO", f"Created directory {swarm_key_path.parent}")

        with open(swarm_key_path, "w", encoding="utf-8") as file:
            file.write(swarm_key)

        swarm_key_path.chmod(0o600)

        log("INFO", f"Swarm key generated and saved to {swarm_key_path}")
    except Exception as error:
        error_msg = f"Failed to save swarm key: {error}"
        log("ERROR", error_msg)
        raise Exception(error_msg) from error

def main():
    parser = argparse.ArgumentParser(description="PKI configuration helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    configure_parser = subparsers.add_parser(
        "configure",
        help="Patch cert-gen template and render final config",
    )
    configure_parser.add_argument("--template", required=True, help="Path to cert-gen config template")
    configure_parser.add_argument("--output", required=True, help="Path to rendered cert-gen config")

    configure_sync_client_parser = subparsers.add_parser(
        "configure-sync-client",
        help="Render PKI sync-client swarm-env config",
    )
    configure_sync_client_parser.add_argument(
        "--config",
        default="/sp/swarm/config.yaml",
        help="Path to swarm config (default: /sp/swarm/config.yaml)",
    )
    configure_sync_client_parser.add_argument(
        "--output",
        required=True,
        help="Path to rendered sync-client config",
    )

    get_vm_mode_parser = subparsers.add_parser(
        "get-vm-mode",
        help="Detect vm-mode (init/normal) from /sp/swarm/config.yaml and save to file",
    )
    get_vm_mode_parser.add_argument(
        "--config",
        default="/sp/swarm/config.yaml",
        help="Path to swarm config (default: /sp/swarm/config.yaml)",
    )
    get_vm_mode_parser.add_argument(
        "--output",
        required=True,
        help="Path to output vm-mode file",
    )

    args = parser.parse_args()

    if args.command == "configure":
        return run_configure(Path(args.template), Path(args.output))

    if args.command == "configure-sync-client":
        return run_configure_sync_client(Path(args.config), Path(args.output))

    if args.command == "get-vm-mode":
        return run_get_vm_mode(Path(args.config), Path(args.output))

    log("ERROR", f"Unsupported command: {args.command}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
