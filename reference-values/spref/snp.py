"""AMD SEV-SNP reference values, computed from the build artifacts.

The SEV-SNP launch digest is a pure function of the guest firmware, the kernel,
the initrd, the kernel command line and the vCPU configuration, so CI can
compute it from the reproducible build without any AMD hardware. The digest is
produced by the upstream reference implementation `sev-snp-measure`
(https://github.com/virtee/sev-snp-measure), pinned in requirements.txt, which
is also what a customer runs to reproduce the value.

`mrenclave` is the 32-byte identifier the Super Protocol PKI join policy uses.
It is published next to the launch digest so the external (CoRIM) and the
internal (signed mrEnclave registry) values can be cross-checked against each
other; see ../README.md.
"""

import hashlib
import os
import shutil
import struct
import subprocess

# AMD EPYC Milan family/model/stepping. Normalising on a single Milan vCPU is
# what makes the published value independent of the vCPU count and the CPU
# model of the host (docs/04-vm-measurements.md, "Normalization").
AMD_EPYC_MILAN_CPUINFO = (25, 1, 1)
NORMALIZED_VCPUS = 1
NORMALIZED_VCPU_TYPE = "EPYC-Milan"

# Defaults of the mrEnclave wrapper, matching
# @super-protocol/attestation-common `createSnpMrEnclaveCalculatorCore`.
NORMALIZED_VMPL = 0
NORMALIZED_POLICY = 0x30000

# SHA-256 of an empty file: the initrd hash a VM booted without an initrd
# contributes to the launch digest.
EMPTY_INITRD_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


class SnpError(Exception):
    pass


def cpu_sig(family, model, stepping):
    """CPUID signature from family/model/stepping (AMD publication #25481)."""
    family_low = 0xF if family > 0xF else family
    family_high = (family - 0xF) & 0xFF if family > 0xF else 0
    return (
        (family_high << 20)
        | ((model >> 4 & 0xF) << 16)
        | (family_low << 8)
        | ((model & 0xF) << 4)
        | (stepping & 0xF)
    ) & 0xFFFFFFFF


MILAN_SIG = cpu_sig(*AMD_EPYC_MILAN_CPUINFO)


def cmdline_sha256(cmdline):
    """SEV-SNP hashes the NUL-terminated command line, as QEMU passes it."""
    return hashlib.sha256(cmdline.encode("utf-8") + b"\x00").hexdigest()


def mrenclave(launch_digest, vmpl=NORMALIZED_VMPL, policy=NORMALIZED_POLICY):
    """mrEnclave = SHA-256(launchDigest || vmpl(u32 LE) || policy(u64 LE))."""
    if len(launch_digest) != 48:
        raise SnpError(f"launch digest must be 48 bytes, got {len(launch_digest)}")
    return hashlib.sha256(launch_digest + struct.pack("<IQ", vmpl, policy)).hexdigest()


def launch_digest(
    ovmf_path,
    kernel_path,
    cmdline,
    initrd_path=None,
    vcpus=NORMALIZED_VCPUS,
    vcpu_type=NORMALIZED_VCPU_TYPE,
    sev_snp_measure=None,
):
    """Compute the SEV-SNP launch digest with the pinned sev-snp-measure."""
    tool = sev_snp_measure or os.environ.get("SEV_SNP_MEASURE") or shutil.which("sev-snp-measure")
    if not tool:
        raise SnpError(
            "sev-snp-measure not found; install it with "
            "`pip install -r reference-values/requirements.txt` or set SEV_SNP_MEASURE"
        )

    for label, path in (("OVMF", ovmf_path), ("kernel", kernel_path)):
        if not os.path.isfile(path):
            raise SnpError(f"{label} not found: {path}")

    argv = [
        tool,
        "--mode=snp",
        f"--vcpus={vcpus}",
        f"--vcpu-type={vcpu_type}",
        f"--ovmf={ovmf_path}",
        f"--kernel={kernel_path}",
        f"--append={cmdline}",
        "--output-format=hex",
    ]
    if initrd_path:
        argv.append(f"--initrd={initrd_path}")

    result = subprocess.run(argv, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SnpError(
            f"sev-snp-measure failed with exit code {result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )

    value = result.stdout.strip().splitlines()[-1].strip() if result.stdout.strip() else ""
    try:
        raw = bytes.fromhex(value)
    except ValueError as exc:
        raise SnpError(f"sev-snp-measure returned {value!r}, which is not hex") from exc
    if len(raw) != 48:
        raise SnpError(f"sev-snp-measure returned {len(raw)} bytes, expected 48")
    return raw


def compute(build, artifact_dir, vm_json, rootfs_verity_hash, cmdline_profiles, sev_snp_measure=None):
    """The ``sev-snp`` platform section of the manifest, one entry per profile."""
    ovmf_path = os.path.join(artifact_dir, vm_json["bios_amd"]["filename"])
    kernel_path = os.path.join(artifact_dir, vm_json["kernel"]["filename"])

    profiles = {}
    for name, template in sorted(cmdline_profiles.items()):
        cmdline = template.format(build=build, rootfs_verity_hash=rootfs_verity_hash)
        digest = launch_digest(
            ovmf_path, kernel_path, cmdline, sev_snp_measure=sev_snp_measure
        )
        profiles[name] = {
            "kernel_cmdline": cmdline,
            "kernel_cmdline_sha256": cmdline_sha256(cmdline),
            "launch_digest_sha384": digest.hex(),
            "mrenclave_sha256": mrenclave(digest),
        }

    return {
        "source": "computed-from-build-artifacts",
        "tool": "sev-snp-measure",
        "normalization": {
            "vcpus": NORMALIZED_VCPUS,
            "vcpu_type": NORMALIZED_VCPU_TYPE,
            "vcpu_sig": f"0x{MILAN_SIG:08x}",
            "vmpl": NORMALIZED_VMPL,
            "policy": f"0x{NORMALIZED_POLICY:x}",
        },
        "inputs": {
            "ovmf_sha256": vm_json["bios_amd"]["sha256"],
            "kernel_sha256": vm_json["kernel"]["sha256"],
            "initrd_sha256": EMPTY_INITRD_SHA256,
        },
        "cmdline_profiles": profiles,
    }
