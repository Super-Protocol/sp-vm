#!/usr/bin/env python3

import sys
import os
import socket
import json
import urllib.request
import urllib.error
from pathlib import Path

from provision_plugin_sdk import ProvisionPlugin, PluginInput, PluginOutput

# Configuration
TIMEOUT = float(os.environ.get("GEO_TIMEOUT_SECS", "5"))

# Property keys
P_LAT = "geo_latitude"
P_LON = "geo_longitude"
P_COUNTRY = "geo_country"
P_CITY = "geo_city"

# Plugin setup
plugin = ProvisionPlugin()


# Helper functions

def read_url(url: str, timeout: float) -> bytes:
    """Fetch URL with custom User-Agent."""
    req = urllib.request.Request(url, headers={"User-Agent": "swarm-geo/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def guess_ip() -> str | None:
    """Try to fetch public IP from external service."""
    try:
        data = read_url("https://api.ipify.org?format=json", TIMEOUT)
        js = json.loads(data.decode("utf-8", errors="ignore"))
        ip = js.get("ip")
        # Validate ip
        socket.inet_aton(ip)
        return ip
    except Exception:
        return None


def _try_fetch(url: str) -> dict | None:
    """Attempt to fetch URL and parse JSON."""
    try:
        raw = read_url(url, TIMEOUT)
        js = json.loads(raw.decode("utf-8", errors="ignore"))
        return js
    except (urllib.error.URLError, socket.timeout, ValueError, json.JSONDecodeError):
        return None


def fetch_geo(ip: str | None) -> dict | None:
    """Fetch geolocation data from multiple providers."""
    # Providers: will stop on first successful response.
    providers = [
        "https://ipapi.co/json",                 # ipapi.co
        "https://ipinfo.io",                     # ipinfo.io
        "https://ipwho.is",                      # ipwho.is
        "http://ip-api.com/json",                # ip-api.com
        "https://ifconfig.co/json",              # ifconfig.co
    ]

    for base in providers:
        base = base.rstrip("/")
        url = base
        # Build provider-specific URL including IP when available
        if "ipinfo.io" in base:
            url = f"{base}/{ip}/json" if ip else f"{base}/json"
        elif "ipapi.co" in base:
            url = f"{base}/{ip}/json" if ip else f"{base}/json"
        elif "ipwho.is" in base:
            url = f"{base}/{ip}" if ip else base
        elif "ip-api.com" in base:
            url = f"{base}/{ip}" if ip else base
        elif "ifconfig.co" in base:
            url = base  # ignore ip
        else:
            # Generic: append ip if provided
            url = f"{base}/{ip}" if ip else base

        js = _try_fetch(url)
        if not js:
            continue
        # Validate provider-specific success flags
        if "ipwho.is" in base and js.get("success") is False:
            continue
        if "ip-api.com" in base and js.get("status") == "fail":
            continue
        # Otherwise accept
        return js

    return None


def extract_fields(geo: dict) -> dict:
    """Normalize multiple providers to common fields."""
    # Candidates:
    # - ipapi.co: latitude, longitude, country_name, country, city
    # - ipinfo.io: loc -> "lat,lon", country (code), city
    # - ipwho.is: latitude, longitude, country, city
    # - ip-api.com: lat, lon, country, city
    # - ifconfig.co: latitude, longitude, country, city
    lat = geo.get("latitude") or geo.get("lat")
    lon = geo.get("longitude") or geo.get("lon")

    if (lat is None or lon is None) and isinstance(geo.get("loc"), str):
        try:
            loc = geo.get("loc").split(",")
            if len(loc) == 2:
                lat = lat or loc[0].strip()
                lon = lon or loc[1].strip()
        except Exception:
            pass

    country = (
        geo.get("country_name") or  # ipapi
        geo.get("country") or        # many providers (might be code)
        (geo.get("country_name_en") if isinstance(geo.get("country_name_en"), str) else None)
    ) or ""

    city = geo.get("city") or geo.get("region_city") or ""

    # Convert to strings (provision node properties are strings)
    result = {}
    if lat is not None:
        result[P_LAT] = str(lat)
    if lon is not None:
        result[P_LON] = str(lon)
    if country:
        result[P_COUNTRY] = str(country)
    if city:
        result[P_CITY] = str(city)
    return result


# Plugin commands

@plugin.command('apply')
def handle_apply(input_data: PluginInput) -> PluginOutput:
    """Determine node GeoIP info and record as measurements."""
    local_node_id = input_data.local_node_id
    local_state = input_data.local_state or {}

    # Try to get IP
    ip = guess_ip()
    if not ip:
        print("[!] Failed to determine public IP", file=sys.stderr)
        return PluginOutput(status='completed', local_state=local_state)

    print(f"[*] Detected public IP: {ip}", file=sys.stderr)

    # Fetch geolocation
    geo = fetch_geo(ip)
    if not geo:
        print("[!] Failed to fetch geolocation data", file=sys.stderr)
        return PluginOutput(status='completed', local_state=local_state)

    # Extract fields
    fields = extract_fields(geo)
    if not fields:
        print("[!] No geolocation fields extracted", file=sys.stderr)
        return PluginOutput(status='completed', local_state=local_state)

    print(f"[*] Extracted geo fields: {', '.join(fields.keys())}", file=sys.stderr)

    # Convert to measurements
    measurements = []
    for name, value in fields.items():
        measurements.append({
            "type": name,
            "node": local_node_id,
            "target_node": local_node_id,
            "value": value
        })

    return PluginOutput(
        status='completed',
        measurements=measurements,
        local_state=local_state
    )


@plugin.command('health')
def handle_health(input_data: PluginInput) -> PluginOutput:
    """Health check - no action needed for geo service."""
    local_state = input_data.local_state or {}
    return PluginOutput(status='completed', local_state=local_state)


@plugin.command('destroy')
def handle_destroy(input_data: PluginInput) -> PluginOutput:
    """Clean up - no action needed as measurements are time-series."""
    return PluginOutput(
        status='completed',
        local_state={}
    )


if __name__ == "__main__":
    plugin.run()
