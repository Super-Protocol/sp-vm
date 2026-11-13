"""CoRIM / CoMID generation and signing.

The CBOR encoding and the COSE signing are delegated to `cocli`, the CLI of
the Veraison reference implementation (github.com/veraison/corim), pinned in
requirements.txt. Generating the templates here and letting Veraison's own
encoder produce the bytes is what makes the published CoRIM importable by a
Veraison deployment instead of merely CBOR-shaped.

Layout of a generated CoRIM: one reference-value triple per measured
environment, each identified by `environment.class`:

    model                              registers (text-keyed integrity registers)
    ---------------------------------  ------------------------------------------
    sp-vm                              build artifacts and the dm-verity root hash
    sp-vm-sev-snp:<cmdline-profile>    launch-digest, kernel-cmdline, mrenclave
    sp-vm-tdx                          mrtd, rtmr0-normalized, rtmr1..3, mrenclave
    sp-vm-tdx-google                   as sp-vm-tdx
    sp-vm-tdx-azure                    pcr4-normalized, pcr9-normalized, mrenclave
    sp-vm-sev-snp-azure                as sp-vm-tdx-azure

The `version` of every measurement is the sp-vm build identifier, so one CoRIM
describes exactly one release.
"""

import os
import shutil
import subprocess

from . import CORIM_PROFILE, VERSION
from .evidence import AZURE_FLAGS
from .util import b64, digest_entry, stable_uuid, write_canonical_json

ENTITY = {
    "name": "Super Protocol",
    "regid": "https://superprotocol.com",
}
COMID_ROLES = ["tagCreator", "creator", "maintainer"]
CORIM_ROLES = ["manifestCreator"]
LANG = "en-GB"


class CorimError(Exception):
    pass


def _environment(platform):
    model = "sp-vm" if platform is None else f"sp-vm-{platform}"
    return {
        "class": {
            "id": {"type": "uuid", "value": stable_uuid("sp-vm", model)},
            "vendor": ENTITY["name"],
            "model": model,
        }
    }


def _registers(entries):
    return {
        name: {"key-type": "text", "value": [value]} for name, value in sorted(entries.items())
    }


def _measurement(build, registers, raw_value=None):
    value = {
        "version": {"value": build, "scheme": "alphanumeric"},
        "integrity-registers": _registers(registers),
    }
    if raw_value is not None:
        value["raw-value"] = {"type": "bytes", "value": b64(raw_value)}
    return {"value": value}


def _triple(build, platform, registers, raw_value=None):
    return {
        "environment": _environment(platform),
        "measurements": [_measurement(build, registers, raw_value)],
    }


def _sha256_register(hex_digest):
    return digest_entry("sha-256", bytes.fromhex(hex_digest))


def _sha384_register(hex_digest):
    return digest_entry("sha-384", bytes.fromhex(hex_digest))


def artifact_triple(manifest):
    build = manifest["build"]
    artifacts = manifest["artifacts"]
    registers = {
        "image": _sha256_register(artifacts["image"]["sha256"]),
        "image-uncompressed": _sha256_register(artifacts["image"]["uncompressed_sha256"]),
        "kernel": _sha256_register(artifacts["kernel"]["sha256"]),
        "bios": _sha256_register(artifacts["bios"]["sha256"]),
        "bios-amd": _sha256_register(artifacts["bios_amd"]["sha256"]),
        "bios-tdx": _sha256_register(artifacts["bios_tdx"]["sha256"]),
        "rootfs-verity-root-hash": _sha256_register(
            manifest["rootfs"]["verity_root_hash_sha256"]
        ),
    }
    return _triple(build, None, registers)


def platform_triples(manifest):
    build = manifest["build"]
    triples = []

    for platform, section in sorted(manifest["platforms"].items()):
        if platform == "sev-snp":
            for profile, values in sorted(section["cmdline_profiles"].items()):
                triples.append(
                    _triple(
                        build,
                        f"sev-snp:{profile}",
                        {
                            "launch-digest": _sha384_register(values["launch_digest_sha384"]),
                            "kernel-cmdline": _sha256_register(values["kernel_cmdline_sha256"]),
                            "mrenclave": _sha256_register(values["mrenclave_sha256"]),
                        },
                    )
                )
        elif platform in ("tdx", "tdx-google"):
            triples.append(
                _triple(
                    build,
                    platform,
                    {
                        "mrtd": _sha384_register(section["mrtd"]),
                        # Raw RTMR0 is deliberately not published: it carries the
                        # dynamic boot events that the normalisation strips, so it
                        # differs between instances of the same release
                        # (docs/04-vm-measurements.md, "RTMR0 Normalization").
                        "rtmr0-normalized": _sha384_register(section["rtmr0_normalized"]),
                        "rtmr1": _sha384_register(section["rtmr1"]),
                        "rtmr2": _sha384_register(section["rtmr2"]),
                        "rtmr3": _sha384_register(section["rtmr3"]),
                        "mrenclave": _sha256_register(section["mrenclave_sha256"]),
                    },
                    raw_value=bytes.fromhex(section["td_attributes"]),
                )
            )
        elif platform in ("tdx-azure", "sev-snp-azure"):
            # The flag bytes are concatenated in the order mrEnclave uses, not
            # alphabetically (docs/08-azure-attestation.md, "Formula").
            flags = bytes(
                1 if section["vm_configuration"][name] else 0
                for name in AZURE_FLAGS[platform]
            )
            triples.append(
                _triple(
                    build,
                    platform,
                    {
                        "pcr4-normalized": _sha256_register(section["pcr4_normalized"]),
                        "pcr9-normalized": _sha256_register(section["pcr9_normalized"]),
                        "mrenclave": _sha256_register(section["mrenclave_sha256"]),
                    },
                    raw_value=flags,
                )
            )
        else:
            raise CorimError(f"no CoMID mapping for platform {platform!r}")

    return triples


def comid_template(manifest):
    build = manifest["build"]
    return {
        "lang": LANG,
        "tag-identity": {"id": stable_uuid("comid", build), "version": 0},
        "entities": [dict(ENTITY, roles=COMID_ROLES)],
        "triples": {"reference-values": [artifact_triple(manifest)] + platform_triples(manifest)},
    }


def corim_template(manifest, not_before, not_after):
    return {
        "corim-id": stable_uuid("corim", manifest["build"]),
        "profiles": [CORIM_PROFILE],
        "validity": {"not-before": not_before, "not-after": not_after},
        "entities": [dict(ENTITY, roles=CORIM_ROLES)],
    }


def meta_template(signer_name, not_before, not_after):
    return {
        "signer": {"name": signer_name, "uri": ENTITY["regid"]},
        "validity": {"not-before": not_before, "not-after": not_after},
    }


def json_document(manifest, comid, corim, meta):
    """The `.corim.json` deliverable: the CoRIM content as a single document."""
    return {
        "generator": {"name": "sp-vm reference-values", "version": VERSION},
        "meta": meta,
        "corim": dict(corim, tags=[comid]),
        "reference_values": manifest,
    }


def _cocli(cocli=None):
    tool = cocli or os.environ.get("COCLI") or shutil.which("cocli")
    if not tool:
        raise CorimError(
            "cocli not found; install it with "
            "`go install github.com/veraison/corim/cocli@v1.1.2` or set COCLI"
        )
    return tool


def _run(argv):
    result = subprocess.run(argv, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise CorimError(
            f"{os.path.basename(argv[0])} {argv[1] if len(argv) > 1 else ''} failed: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout


def encode(out_dir, comid, corim, unsigned_name, cocli=None):
    """Write the templates and produce the unsigned, CBOR-encoded CoRIM."""
    tool = _cocli(cocli)
    templates = os.path.join(out_dir, "templates")
    os.makedirs(templates, exist_ok=True)

    comid_path = os.path.join(templates, "comid.json")
    corim_path = os.path.join(templates, "corim.json")
    write_canonical_json(comid_path, comid)
    write_canonical_json(corim_path, corim)

    comid_cbor = os.path.join(templates, "comid.cbor")
    _run([tool, "comid", "create", "--template", comid_path, "--output-dir", templates])
    if not os.path.exists(comid_cbor):
        raise CorimError(f"cocli comid create did not produce {comid_cbor}")
    _run([tool, "comid", "validate", "--file", comid_cbor])

    unsigned = os.path.join(out_dir, unsigned_name)
    _run(
        [tool, "corim", "create", "--template", corim_path, "--comid", comid_cbor,
         "--output", unsigned]
    )
    return unsigned


def sign(unsigned, meta_path, key_path, output, cocli=None):
    """COSE-sign an unsigned CoRIM with the Reference-Values key."""
    _run([_cocli(cocli), "corim", "sign", "--file", unsigned, "--key", key_path,
          "--meta", meta_path, "--output", output])
    return output


def display(signed, cocli=None):
    return _run([_cocli(cocli), "corim", "display", "--file", signed, "--show-tags"])
