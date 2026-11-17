"""Reference values that are computed in CI from the reproducible build.

Everything in here is a plain digest of a published build artifact, so a
customer who rebuilds sp-vm from source reproduces it without any hardware.
"""

import hashlib
import json
import os

from .util import sha256_file

# vm.json key -> the file it describes. Only these keys are published as
# reference values; an unknown key is an error, so that a new artifact cannot
# silently stay out of the manifest.
ARTIFACT_KEYS = (
    "image",
    "kernel",
    "bios",
    "bios_amd",
    "bios_tdx",
    "rootfs_hash",
)


class ArtifactError(Exception):
    pass


def load_vm_json(artifact_dir):
    path = os.path.join(artifact_dir, "vm.json")
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        raise ArtifactError(f"cannot read {path}: {exc}") from exc

    vm_json = json.loads(raw)
    missing = [key for key in ARTIFACT_KEYS if key not in vm_json]
    if missing:
        raise ArtifactError(f"{path} is missing the artifact entries: {', '.join(missing)}")
    unknown = [key for key in vm_json if key not in ARTIFACT_KEYS]
    if unknown:
        raise ArtifactError(
            f"{path} has artifact entries this generator does not know how to publish: "
            f"{', '.join(sorted(unknown))}"
        )
    return vm_json, raw


def read_rootfs_verity_hash(artifact_dir):
    """The dm-verity root hash of the rootfs partition (rootfs_hash.txt)."""
    path = os.path.join(artifact_dir, "rootfs_hash.txt")
    try:
        with open(path, "r", encoding="ascii") as handle:
            value = handle.read().strip()
    except OSError as exc:
        raise ArtifactError(f"cannot read {path}: {exc}") from exc

    if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
        raise ArtifactError(f"{path}: expected a 32-byte lower-case hex root hash, got {value!r}")
    return value


def collect(artifact_dir, verify_digests=True):
    """Build the ``artifacts`` section of the manifest.

    ``verify_digests`` re-hashes every artifact present in ``artifact_dir`` and
    fails on a mismatch with vm.json, which is what makes the manifest a
    statement about the build output rather than about vm.json alone.
    """
    vm_json, raw_vm_json = load_vm_json(artifact_dir)
    artifacts = {}

    for key in ARTIFACT_KEYS:
        entry = vm_json[key]
        published = {
            "filename": entry["filename"],
            "sha256": entry["sha256"],
            "storj_bucket": entry["bucket"],
            "storj_prefix": entry["prefix"],
        }
        for extra in ("compression", "uncompressed_filename", "uncompressed_sha256", "uncompressed_size"):
            if extra in entry:
                published[extra] = entry[extra]

        if verify_digests:
            _verify(artifact_dir, key, entry)

        artifacts[key] = published

    return {
        "artifacts": artifacts,
        "rootfs": {
            "verity_scheme": "dm-verity",
            "verity_root_hash_sha256": read_rootfs_verity_hash(artifact_dir),
        },
        "vm_json_sha256": hashlib.sha256(raw_vm_json).hexdigest(),
    }


def _verify(artifact_dir, key, entry):
    for filename, expected in (
        (entry["filename"], entry["sha256"]),
        (entry.get("uncompressed_filename"), entry.get("uncompressed_sha256")),
    ):
        if not filename or not expected:
            continue
        path = os.path.join(artifact_dir, filename)
        if not os.path.exists(path):
            # Not every artifact is kept next to vm.json (the raw image is
            # usually deleted after compression). Absence is not an error; a
            # present file that disagrees with vm.json is.
            continue
        actual = sha256_file(path)
        if actual != expected:
            raise ArtifactError(
                f"{key}: {filename} has sha256 {actual}, but vm.json declares {expected}"
            )
