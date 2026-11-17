"""The human-readable reference-values manifest.

The manifest is the single source the CoRIM is generated from. It is
deterministic: the same build artifacts and the same reference-evidence
bundles always produce byte-identical JSON, which is what lets a customer
regenerate it from a clean rebuild and compare.
"""

import os

from . import MANIFEST_SCHEMA, VERSION
from . import artifacts as artifacts_mod
from . import evidence as evidence_mod
from . import snp as snp_mod

CMDLINE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cmdlines")


class ManifestError(Exception):
    pass


def load_cmdline_profiles(cmdline_dir=None):
    """Read the kernel command-line templates the launch digest is computed for."""
    root = cmdline_dir or CMDLINE_DIR
    if not os.path.isdir(root):
        raise ManifestError(f"no kernel command-line profiles directory: {root}")

    profiles = {}
    for name in sorted(os.listdir(root)):
        if not name.endswith(".cmdline"):
            continue
        with open(os.path.join(root, name), "r", encoding="utf-8") as handle:
            lines = [
                line.strip()
                for line in handle
                if line.strip() and not line.lstrip().startswith("#")
            ]
        if len(lines) != 1:
            raise ManifestError(
                f"{os.path.join(root, name)}: expected exactly one command-line, got {len(lines)}"
            )
        profiles[name[: -len(".cmdline")]] = lines[0]

    if not profiles:
        raise ManifestError(f"{root} contains no *.cmdline profile")
    return profiles


def build(build_id, artifact_dir, evidence_dir=None, cmdline_dir=None, sev_snp_measure=None,
          verify_digests=True, sp_vm_commit=None):
    collected = artifacts_mod.collect(artifact_dir, verify_digests=verify_digests)
    vm_json, _ = artifacts_mod.load_vm_json(artifact_dir)

    declared_prefix = vm_json["image"]["prefix"]
    if declared_prefix != build_id:
        raise ManifestError(
            f"vm.json describes build {declared_prefix!r}, but {build_id!r} was requested"
        )

    rootfs_verity_hash = collected["rootfs"]["verity_root_hash_sha256"]
    platforms = {
        "sev-snp": snp_mod.compute(
            build_id,
            artifact_dir,
            vm_json,
            rootfs_verity_hash,
            load_cmdline_profiles(cmdline_dir),
            sev_snp_measure=sev_snp_measure,
        )
    }

    evidence_sources = {}
    if evidence_dir:
        for platform, (path, bundle) in evidence_mod.discover(evidence_dir, build_id).items():
            platforms[platform] = evidence_mod.verify_and_normalize(path, bundle)
            evidence_sources[platform] = os.path.relpath(path, evidence_dir)

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "build": build_id,
        "generator": {"name": "sp-vm reference-values", "version": VERSION},
        "artifacts": collected["artifacts"],
        "rootfs": collected["rootfs"],
        "vm_json_sha256": collected["vm_json_sha256"],
        "platforms": platforms,
    }
    if sp_vm_commit:
        manifest["sp_vm_commit"] = sp_vm_commit
    if evidence_sources:
        manifest["reference_evidence"] = evidence_sources
    return manifest
