"""Command line of the sp-vm reference-values generator.

    python3 -m spref generate --build <build> --artifact-dir out --out-dir rv
    python3 -m spref sign     --in-dir rv --key reference-values.jwk
    python3 -m spref verify   --corim rv/sp-vm-<build>.corim.cbor --key <pub>.jwk

`generate` needs only the build output and is deterministic. `sign` is a
separate step so it can run on the offline machine that holds the
Reference-Values key. `verify` needs nothing but the published public key.
"""

import argparse
import datetime
import json
import os
import sys

from . import VERSION
from .artifacts import ArtifactError
from .corim import CorimError, comid_template, corim_template, display, encode, json_document
from .corim import meta_template, sign as sign_corim
from .cose import CoseError, public_key_from_jwk, verify_sign1
from .evidence import EvidenceError
from .keys import KeyConversionError, pem_to_jwk
from .manifest import ManifestError, build as build_manifest
from .snp import SnpError
from .util import write_canonical_json

DEFAULT_VALIDITY_DAYS = 3650
SIGNER_NAME = "Super Protocol sp-vm Reference Values"

MANIFEST_NAME = "reference-values.json"
META_NAME = "corim-meta.json"


def _names(build_id):
    return {
        "manifest": MANIFEST_NAME,
        "unsigned": f"sp-vm-{build_id}.corim-unsigned.cbor",
        "signed": f"sp-vm-{build_id}.corim.cbor",
        "json": f"sp-vm-{build_id}.corim.json",
    }


def _rfc3339(moment):
    return moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def cmd_generate(args):
    manifest = build_manifest(
        args.build,
        args.artifact_dir,
        evidence_dir=args.evidence_dir,
        cmdline_dir=args.cmdline_dir,
        sev_snp_measure=args.sev_snp_measure,
        verify_digests=not args.no_verify_digests,
        sp_vm_commit=args.sp_vm_commit,
    )

    not_before = args.not_before or _rfc3339(datetime.datetime.now(datetime.timezone.utc))
    not_after = args.not_after or _rfc3339(
        datetime.datetime.fromisoformat(not_before.replace("Z", "+00:00"))
        + datetime.timedelta(days=DEFAULT_VALIDITY_DAYS)
    )

    comid = comid_template(manifest)
    corim = corim_template(manifest, not_before, not_after)
    meta = meta_template(args.signer_name, not_before, not_after)

    names = _names(args.build)
    os.makedirs(args.out_dir, exist_ok=True)
    write_canonical_json(os.path.join(args.out_dir, names["manifest"]), manifest)
    write_canonical_json(
        os.path.join(args.out_dir, names["json"]), json_document(manifest, comid, corim, meta)
    )
    write_canonical_json(os.path.join(args.out_dir, META_NAME), meta)
    unsigned = encode(args.out_dir, comid, corim, names["unsigned"], cocli=args.cocli)

    print(f"reference values for {args.build}:")
    for platform, section in sorted(manifest["platforms"].items()):
        print(f"  {platform:<16} {section['source']}")
    print(f"  manifest       {os.path.join(args.out_dir, names['manifest'])}")
    print(f"  corim (json)   {os.path.join(args.out_dir, names['json'])}")
    print(f"  corim (cbor)   {unsigned} (unsigned)")
    return 0


def cmd_sign(args):
    manifest_path = os.path.join(args.in_dir, MANIFEST_NAME)
    try:
        with open(manifest_path, "r", encoding="utf-8") as handle:
            build_id = json.load(handle)["build"]
    except (OSError, ValueError, KeyError) as exc:
        raise CorimError(f"cannot read the build id from {manifest_path}: {exc}") from exc

    names = _names(build_id)
    unsigned = os.path.join(args.in_dir, names["unsigned"])
    if not os.path.exists(unsigned):
        raise CorimError(f"no unsigned CoRIM at {unsigned}; run `generate` first")

    meta_path = os.path.join(args.in_dir, META_NAME)
    if not os.path.exists(meta_path):
        raise CorimError(f"no CoRIM meta at {meta_path}; run `generate` first")

    signed = sign_corim(
        unsigned, meta_path, args.key, os.path.join(args.in_dir, names["signed"]), cocli=args.cocli
    )
    print(f"signed CoRIM: {signed}")
    return 0


def cmd_verify(args):
    with open(args.key, "r", encoding="utf-8") as handle:
        public_key = public_key_from_jwk(handle.read())

    with open(args.corim, "rb") as handle:
        signed = handle.read()

    payload = verify_sign1(signed, public_key)
    print(f"signature verifies: {args.corim} ({len(signed)} bytes, payload {len(payload)} bytes)")

    if args.expect_payload:
        with open(args.expect_payload, "rb") as handle:
            expected = handle.read()
        if payload != expected:
            raise CorimError(
                f"the signed CoRIM payload differs from {args.expect_payload}: the signed "
                "reference values are not the ones this build produces"
            )
        print(f"payload matches the regenerated CoRIM: {args.expect_payload}")

    if args.show:
        sys.stdout.write(display(args.corim, cocli=args.cocli))
    return 0


def cmd_jwk(args):
    with open(args.input, "rb") as handle:
        pem = handle.read()
    jwk = pem_to_jwk(pem, public_only=args.public, kid=args.kid)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(jwk)
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(jwk)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="spref", description="Generate and sign sp-vm Reference Values (CoRIM)"
    )
    parser.add_argument("--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="command", required=True)

    generate = sub.add_parser("generate", help="compute the reference values and the unsigned CoRIM")
    generate.add_argument("--build", required=True, help="sp-vm build id, e.g. build-448-release")
    generate.add_argument("--artifact-dir", required=True, help="build output containing vm.json")
    generate.add_argument("--out-dir", required=True)
    generate.add_argument("--evidence-dir", help="reference-values/evidence")
    generate.add_argument("--cmdline-dir", help="reference-values/cmdlines")
    generate.add_argument("--sev-snp-measure", help="path to the sev-snp-measure executable")
    generate.add_argument("--cocli", help="path to the cocli executable")
    generate.add_argument("--sp-vm-commit", help="sp-vm commit the release was built from")
    generate.add_argument("--signer-name", default=SIGNER_NAME)
    generate.add_argument("--not-before", help="RFC 3339; defaults to now")
    generate.add_argument("--not-after", help="RFC 3339; defaults to 10 years after --not-before")
    generate.add_argument(
        "--no-verify-digests",
        action="store_true",
        help="trust vm.json instead of re-hashing the artifacts next to it",
    )
    generate.set_defaults(func=cmd_generate)

    sign = sub.add_parser("sign", help="COSE-sign the unsigned CoRIM with the Reference-Values key")
    sign.add_argument("--in-dir", required=True, help="output directory of `generate`")
    sign.add_argument("--key", required=True, help="signing key in JWK format")
    sign.add_argument("--cocli", help="path to the cocli executable")
    sign.set_defaults(func=cmd_sign)

    verify = sub.add_parser("verify", help="verify a signed CoRIM with the published public key")
    verify.add_argument("--corim", required=True)
    verify.add_argument("--key", required=True, help="public key in JWK format")
    verify.add_argument(
        "--expect-payload",
        help="unsigned CoRIM to compare the signed payload against, byte for byte",
    )
    verify.add_argument("--show", action="store_true", help="print the CoRIM content")
    verify.add_argument("--cocli", help="path to the cocli executable")
    verify.set_defaults(func=cmd_verify)

    jwk = sub.add_parser("jwk", help="re-encode a PEM EC key as the JWK cocli uses")
    jwk.add_argument("--in", dest="input", required=True, help="PEM private or public key")
    jwk.add_argument("--out", help="write the JWK here instead of stdout")
    jwk.add_argument("--public", action="store_true", help="drop the private half")
    jwk.add_argument("--kid", help="key id to record in the JWK")
    jwk.set_defaults(func=cmd_jwk)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (ArtifactError, CorimError, CoseError, EvidenceError, KeyConversionError, ManifestError,
            SnpError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
