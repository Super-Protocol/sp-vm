"""Small helpers shared by the reference-value calculators."""

import base64
import hashlib
import json
import re
import uuid

from . import NAMESPACE_UUID

_HEX_RE = re.compile(r"\A[0-9a-f]*\Z")


def parse_hex(value, size, label):
    """Decode a lower-case hex string of exactly ``size`` bytes."""
    if not isinstance(value, str):
        raise ValueError(f"{label}: expected a hex string, got {type(value).__name__}")
    if not _HEX_RE.match(value):
        raise ValueError(f"{label}: expected lower-case hex, got {value!r}")
    if len(value) != size * 2:
        raise ValueError(f"{label}: expected {size} bytes ({size * 2} hex chars), got {len(value)}")
    return bytes.fromhex(value)


def parse_hex_any(value, label):
    """Decode a lower-case hex string of any (even) length."""
    if not isinstance(value, str):
        raise ValueError(f"{label}: expected a hex string, got {type(value).__name__}")
    if not _HEX_RE.match(value) or len(value) % 2:
        raise ValueError(f"{label}: expected an even number of lower-case hex chars, got {value!r}")
    return bytes.fromhex(value)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def b64(raw):
    """Base64 (standard alphabet, padded) as used by CoMID JSON digests."""
    return base64.b64encode(raw).decode("ascii")


def digest_entry(algorithm, raw):
    """A CoMID JSON digest: ``<alg>;<base64>``."""
    return f"{algorithm};{b64(raw)}"


def stable_uuid(*parts):
    """Derive a stable UUIDv5 from the sp-vm namespace and the given parts."""
    return str(uuid.uuid5(uuid.UUID(NAMESPACE_UUID), "/".join(parts)))


def canonical_json(obj):
    """Deterministic JSON: sorted keys, fixed separators, trailing newline."""
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write_canonical_json(path, obj):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(canonical_json(obj))
