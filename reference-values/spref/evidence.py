"""Reference values taken from a verified reference boot of the release.

Intel TDX RTMR1-RTMR3 and the Azure CVM vTPM PCRs are produced by the boot
itself, not by the build, so CI cannot predict them. They are collected once
per release from a reference VM (the Measurement API of the running VM, see
docs/04-vm-measurements.md) and committed as a reference-evidence bundle under
reference-values/evidence/<build>/<platform>.json.

Nothing from a bundle is published unless this module can re-derive it:

* TDX    - RTMR0 is replayed from the event log and must equal quote RTMR0;
           the normalised RTMR0 and mrEnclave are recomputed and must equal the
           mrEnclave the Measurement API reported.
* Azure  - PCR4' and PCR9' are replayed from the event log and mrEnclave is
           recomputed from them and the vm-configuration flags; it must equal
           the mrEnclave the Measurement API reported.

A bundle that does not reproduce its own mrEnclave is rejected, so a mistyped
or tampered register cannot reach a published, signed CoRIM.
"""

import hashlib
import json
import os

from . import EVIDENCE_SCHEMA
from .util import parse_hex, parse_hex_any

TDX_PLATFORMS = ("tdx", "tdx-google")
AZURE_PLATFORMS = ("tdx-azure", "sev-snp-azure")
PLATFORMS = TDX_PLATFORMS + AZURE_PLATFORMS

# Only the firmware-identity events survive RTMR0 normalisation
# (docs/04-vm-measurements.md, "RTMR0 Normalization").
RTMR0_NORMALIZED_EVENT_TYPES = frozenset(
    ("EV_EFI_PLATFORM_FIRMWARE_BLOB", "EV_EFI_PLATFORM_FIRMWARE_BLOB2")
)

# Azure vm-configuration flags, in the order they are concatenated into
# mrEnclave (docs/08-azure-attestation.md, "Formula").
AZURE_FLAGS = {
    "tdx-azure": (
        "secure-boot",
        "tpm-enabled",
        "console-enabled",
        "interactive-console-enabled",
        "filtered-vpci-devices-allowed",
    ),
    "sev-snp-azure": ("secure-boot", "tpm-enabled", "console-enabled"),
}

# Event types skipped unconditionally, and those skipped only when the event
# digest is the SHA-256 of the event's own data.
AZURE_SKIPPED_EVENT_TYPES = frozenset(("EV_NO_ACTION",))
AZURE_SELF_DESCRIBING_EVENT_TYPES = frozenset(("EV_EFI_ACTION", "EV_SEPARATOR"))

AZURE_PCRS = (4, 9)

# Fields every bundle carries, whatever the platform.
REQUIRED_FIELDS = ("build", "collected_at", "collected_on", "mrenclave")


class EvidenceError(Exception):
    pass


def rtmr_replay(digests):
    """RTMR = SHA-384(RTMR || eventDigest), starting from 48 zero bytes."""
    acc = bytes(48)
    for digest in digests:
        acc = hashlib.sha384(acc + digest).digest()
    return acc


def pcr_replay(digests):
    """PCR = SHA-256(PCR || eventDigest), starting from 32 zero bytes."""
    acc = bytes(32)
    for digest in digests:
        acc = hashlib.sha256(acc + digest).digest()
    return acc


def tdx_mrenclave(td_attributes, mrtd, rtmr0_normalized, rtmr1, rtmr2, rtmr3):
    return hashlib.sha256(
        td_attributes + mrtd + rtmr0_normalized + rtmr1 + rtmr2 + rtmr3
    ).hexdigest()


def azure_mrenclave(platform, vm_configuration, pcr4, pcr9):
    flags = bytearray()
    for name in AZURE_FLAGS[platform]:
        if name not in vm_configuration:
            raise EvidenceError(f"{platform}: vm_configuration is missing the flag {name!r}")
        value = vm_configuration[name]
        if not isinstance(value, bool):
            raise EvidenceError(
                f"{platform}: vm_configuration flag {name!r} must be a boolean, got {value!r}"
            )
        flags.append(1 if value else 0)
    return hashlib.sha256(bytes(flags) + pcr4 + pcr9).hexdigest()


def load_bundle(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            bundle = json.load(handle)
    except OSError as exc:
        raise EvidenceError(f"cannot read {path}: {exc}") from exc
    except ValueError as exc:
        raise EvidenceError(f"{path} is not valid JSON: {exc}") from exc

    if bundle.get("schema") != EVIDENCE_SCHEMA:
        raise EvidenceError(f"{path}: expected schema {EVIDENCE_SCHEMA}, got {bundle.get('schema')!r}")
    platform = bundle.get("platform")
    if platform not in PLATFORMS:
        raise EvidenceError(f"{path}: unknown platform {platform!r}; expected one of {', '.join(PLATFORMS)}")

    missing = [field for field in REQUIRED_FIELDS if field not in bundle]
    if missing:
        raise EvidenceError(f"{path}: missing field(s): {', '.join(missing)}")
    parse_hex(bundle["mrenclave"], 32, f"{path}: mrenclave")
    return bundle


def discover(evidence_dir, build):
    """Bundles committed for ``build``, keyed by platform."""
    root = os.path.join(evidence_dir, build)
    if not os.path.isdir(root):
        return {}

    bundles = {}
    for name in sorted(os.listdir(root)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(root, name)
        bundle = load_bundle(path)
        platform = bundle["platform"]
        if platform in bundles:
            raise EvidenceError(f"{root}: two bundles for platform {platform!r}")
        if bundle.get("build") != build:
            raise EvidenceError(
                f"{path}: bundle is for build {bundle.get('build')!r}, not {build!r}"
            )
        bundles[platform] = (path, bundle)
    return bundles


def verify_and_normalize(path, bundle):
    """Re-derive a bundle's values and return its manifest section."""
    platform = bundle["platform"]
    if platform in TDX_PLATFORMS:
        return _tdx(path, bundle)
    return _azure(path, bundle)


def _common(bundle):
    section = {
        "source": "reference-boot-evidence",
        "collected_at": bundle["collected_at"],
        "collected_on": bundle["collected_on"],
        "mrenclave_sha256": bundle["mrenclave"],
    }
    if "evidence_sha256" in bundle:
        section["evidence_sha256"] = bundle["evidence_sha256"]
    return section


def _tdx(path, bundle):
    try:
        tdx = bundle["tdx"]
        td_attributes = parse_hex(tdx["td_attributes"], 8, f"{path}: td_attributes")
        mrtd = parse_hex(tdx["mrtd"], 48, f"{path}: mrtd")
        rtmr = [
            parse_hex(tdx[f"rtmr{index}"], 48, f"{path}: rtmr{index}") for index in range(4)
        ]
        event_log = tdx["rtmr0_event_log"]
    except KeyError as exc:
        raise EvidenceError(f"{path}: missing field {exc.args[0]!r}") from exc

    if not event_log:
        raise EvidenceError(f"{path}: rtmr0_event_log is empty; RTMR0 cannot be replayed")

    digests = []
    normalized_digests = []
    for index, entry in enumerate(event_log):
        try:
            event_type = entry["type"]
            digest = parse_hex(entry["digest"], 48, f"{path}: rtmr0_event_log[{index}].digest")
        except KeyError as exc:
            raise EvidenceError(
                f"{path}: rtmr0_event_log[{index}] is missing {exc.args[0]!r}"
            ) from exc
        digests.append(digest)
        if event_type in RTMR0_NORMALIZED_EVENT_TYPES:
            normalized_digests.append(digest)

    replayed = rtmr_replay(digests)
    if replayed != rtmr[0]:
        raise EvidenceError(
            f"{path}: replaying rtmr0_event_log gives {replayed.hex()}, "
            f"but the quote reports rtmr0 {rtmr[0].hex()}"
        )
    if not normalized_digests:
        raise EvidenceError(
            f"{path}: rtmr0_event_log has no EV_EFI_PLATFORM_FIRMWARE_BLOB(2) event, "
            "so the normalised RTMR0 would not identify any firmware"
        )

    rtmr0_normalized = rtmr_replay(normalized_digests)
    computed = tdx_mrenclave(td_attributes, mrtd, rtmr0_normalized, rtmr[1], rtmr[2], rtmr[3])
    if computed != bundle["mrenclave"]:
        raise EvidenceError(
            f"{path}: mrEnclave recomputed from the registers is {computed}, "
            f"but the bundle reports {bundle['mrenclave']}"
        )

    section = _common(bundle)
    section.update(
        {
            "td_attributes": td_attributes.hex(),
            "mrtd": mrtd.hex(),
            # Raw RTMR0 is an input to the checks above, not a reference value:
            # it includes boot events that vary between instances of the same
            # release. Only the normalised register is published.
            "rtmr0_normalized": rtmr0_normalized.hex(),
            "rtmr1": rtmr[1].hex(),
            "rtmr2": rtmr[2].hex(),
            "rtmr3": rtmr[3].hex(),
        }
    )
    return section


def _azure(path, bundle):
    platform = bundle["platform"]
    try:
        azure = bundle["azure"]
        vm_configuration = azure["vm_configuration"]
        event_log = azure["event_log"]
    except KeyError as exc:
        raise EvidenceError(f"{path}: missing field {exc.args[0]!r}") from exc

    per_pcr = {index: [] for index in AZURE_PCRS}
    for index, entry in enumerate(event_log):
        try:
            pcr = entry["pcr"]
            event_type = entry["type"]
            digest = parse_hex(entry["digest"], 32, f"{path}: event_log[{index}].digest")
        except KeyError as exc:
            raise EvidenceError(f"{path}: event_log[{index}] is missing {exc.args[0]!r}") from exc

        if pcr not in per_pcr:
            raise EvidenceError(
                f"{path}: event_log[{index}] is for PCR{pcr}; only "
                f"{', '.join(f'PCR{p}' for p in AZURE_PCRS)} are used"
            )
        if event_type in AZURE_SKIPPED_EVENT_TYPES:
            continue
        if event_type in AZURE_SELF_DESCRIBING_EVENT_TYPES:
            if "data" not in entry:
                raise EvidenceError(
                    f"{path}: event_log[{index}] is a {event_type} event, so its event data is "
                    "needed to decide whether it is skipped; add the \"data\" field"
                )
            data = parse_hex_any(entry["data"], f"{path}: event_log[{index}].data")
            if hashlib.sha256(data).digest() == digest:
                continue
        per_pcr[pcr].append(digest)

    normalized = {index: pcr_replay(per_pcr[index]) for index in AZURE_PCRS}
    computed = azure_mrenclave(platform, vm_configuration, normalized[4], normalized[9])
    if computed != bundle["mrenclave"]:
        raise EvidenceError(
            f"{path}: mrEnclave recomputed from PCR4'/PCR9' and the vm-configuration flags "
            f"is {computed}, but the bundle reports {bundle['mrenclave']}"
        )

    section = _common(bundle)
    section.update(
        {
            "vm_configuration": {name: bool(vm_configuration[name]) for name in AZURE_FLAGS[platform]},
            "pcr4_normalized": normalized[4].hex(),
            "pcr9_normalized": normalized[9].hex(),
        }
    )
    return section
