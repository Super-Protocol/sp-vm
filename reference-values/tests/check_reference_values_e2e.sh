#!/bin/bash
# End-to-end check of the reference-values pipeline against a real sp-vm build
# output: generate -> sign -> verify, plus a determinism check and, when an
# expected mrEnclave is given, a comparison with the published registry value.
#
# Usage:
#   SP_VM_ARTIFACT_DIR=/path/to/out \
#   SP_VM_BUILD=build-448-release \
#     reference-values/tests/check_reference_values_e2e.sh
#
# Optional:
#   SP_VM_EXPECTED_MRENCLAVE  mrEnclave the build is known to produce
#   SP_VM_EXPECTED_PROFILE    kernel command-line profile it belongs to
#                             (default: openstack-magnum)
#   KEEP_REFERENCE_VALUES_OUTPUT=1   keep the generated artifacts
#
# The artifact directory must contain vm.json, rootfs_hash.txt, OVMF_AMD.fd and
# vmlinuz; the SEV-SNP launch digest is computed from the last two.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REFERENCE_VALUES_DIR="${REPO_ROOT}/reference-values"

: "${SP_VM_ARTIFACT_DIR:?set SP_VM_ARTIFACT_DIR to an sp-vm build output directory}"
: "${SP_VM_BUILD:?set SP_VM_BUILD to the build id, e.g. build-448-release}"
EXPECTED_PROFILE="${SP_VM_EXPECTED_PROFILE:-openstack-magnum}"

for tool in cocli sev-snp-measure openssl python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: $tool is not on PATH" >&2
        exit 1
    fi
done

WORK="$(mktemp -d)"
cleanup() {
    if [[ "${KEEP_REFERENCE_VALUES_OUTPUT:-0}" == "1" ]]; then
        echo "output kept in $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

export PYTHONPATH="${REFERENCE_VALUES_DIR}${PYTHONPATH:+:$PYTHONPATH}"
spref() { python3 -m spref "$@"; }

# Everything that is not derived from the artifacts is pinned, which is what
# the offline signing procedure in reference-values/keys/README.md does.
generate_into() {
    spref generate \
        --build "$SP_VM_BUILD" \
        --artifact-dir "$SP_VM_ARTIFACT_DIR" \
        --evidence-dir "${REFERENCE_VALUES_DIR}/evidence" \
        --out-dir "$1" \
        --not-before 2026-01-01T00:00:00Z \
        --not-after 2036-01-01T00:00:00Z \
        --sp-vm-commit 0000000000000000000000000000000000000000
}

echo "==> generating reference values for ${SP_VM_BUILD}"
generate_into "$WORK/first"

MANIFEST="$WORK/first/reference-values.json"
UNSIGNED="$WORK/first/sp-vm-${SP_VM_BUILD}.corim-unsigned.cbor"
SIGNED="$WORK/first/sp-vm-${SP_VM_BUILD}.corim.cbor"
CORIM_JSON="$WORK/first/sp-vm-${SP_VM_BUILD}.corim.json"

for file in "$MANIFEST" "$UNSIGNED" "$CORIM_JSON"; do
    [[ -s "$file" ]] || { echo "FAIL: $file was not produced" >&2; exit 1; }
done

echo "==> regenerating and comparing (the generator must be deterministic)"
generate_into "$WORK/second" >/dev/null
cmp "$MANIFEST" "$WORK/second/reference-values.json"
cmp "$UNSIGNED" "$WORK/second/sp-vm-${SP_VM_BUILD}.corim-unsigned.cbor"
cmp "$CORIM_JSON" "$WORK/second/sp-vm-${SP_VM_BUILD}.corim.json"

echo "==> signing with a throw-away Reference-Values key"
openssl ecparam -genkey -name secp384r1 -noout -out "$WORK/rv.pem"
spref jwk --in "$WORK/rv.pem" --out "$WORK/rv.jwk" --kid e2e-test
spref jwk --in "$WORK/rv.pem" --out "$WORK/rv.pub.jwk" --public --kid e2e-test
spref sign --in-dir "$WORK/first" --key "$WORK/rv.jwk"
[[ -s "$SIGNED" ]] || { echo "FAIL: $SIGNED was not produced" >&2; exit 1; }

echo "==> verifying the signature with the public key alone"
spref verify --corim "$SIGNED" --key "$WORK/rv.pub.jwk" --expect-payload "$UNSIGNED"

echo "==> rejecting the wrong key"
openssl ecparam -genkey -name secp384r1 -noout -out "$WORK/other.pem"
spref jwk --in "$WORK/other.pem" --out "$WORK/other.pub.jwk" --public
if spref verify --corim "$SIGNED" --key "$WORK/other.pub.jwk" >/dev/null 2>&1; then
    echo "FAIL: a CoRIM verified against an unrelated key" >&2
    exit 1
fi

echo "==> raw RTMR0 is never published as a reference value"
python3 - "$MANIFEST" "$CORIM_JSON" <<'RTMR0_CHECK'
import json
import sys

for path in sys.argv[1:]:
    document = json.load(open(path, encoding="utf-8"))
    manifest = document.get("reference_values", document)
    for platform, section in manifest["platforms"].items():
        if platform not in ("tdx", "tdx-google"):
            continue
        if "rtmr0" in section:
            raise SystemExit(f"FAIL: {path}: {platform} publishes raw rtmr0")
        if "rtmr0_normalized" not in section:
            raise SystemExit(f"FAIL: {path}: {platform} has no normalised rtmr0")
    if '"rtmr0"' in json.dumps(document):
        raise SystemExit(f"FAIL: {path}: a raw rtmr0 register is present")
print("    no raw rtmr0 in the manifest or the CoRIM")
RTMR0_CHECK

echo "==> the CoRIM decodes with Veraison's own tooling"
cocli corim display --file "$SIGNED" --show-tags > "$WORK/display.txt"
grep -q "https://superprotocol.com/corim/sp-vm/1" "$WORK/display.txt"
grep -q "sp-vm-sev-snp:${EXPECTED_PROFILE}" "$WORK/display.txt"

echo "==> every published digest appears in the decoded CoRIM"
python3 - "$MANIFEST" "$WORK/display.txt" <<'PY'
import base64
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
display = open(sys.argv[2], encoding="utf-8").read()

expected = []
for key, entry in manifest["artifacts"].items():
    if key == "rootfs_hash":
        continue
    expected.append(entry["sha256"])
    if "uncompressed_sha256" in entry:
        expected.append(entry["uncompressed_sha256"])
expected.append(manifest["rootfs"]["verity_root_hash_sha256"])
for profile in manifest["platforms"]["sev-snp"]["cmdline_profiles"].values():
    expected += [
        profile["launch_digest_sha384"],
        profile["kernel_cmdline_sha256"],
        profile["mrenclave_sha256"],
    ]

missing = [
    value
    for value in expected
    if base64.b64encode(bytes.fromhex(value)).decode() not in display
]
if missing:
    raise SystemExit("FAIL: not in the decoded CoRIM: " + ", ".join(missing))
print(f"    {len(expected)} values present")
PY

if [[ -n "${SP_VM_EXPECTED_MRENCLAVE:-}" ]]; then
    echo "==> comparing with the published mrEnclave of ${SP_VM_BUILD}"
    ACTUAL="$(python3 -c '
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print(manifest["platforms"]["sev-snp"]["cmdline_profiles"][sys.argv[2]]["mrenclave_sha256"])
' "$MANIFEST" "$EXPECTED_PROFILE")"
    if [[ "$ACTUAL" != "$SP_VM_EXPECTED_MRENCLAVE" ]]; then
        echo "FAIL: profile ${EXPECTED_PROFILE} gives ${ACTUAL}, expected ${SP_VM_EXPECTED_MRENCLAVE}" >&2
        exit 1
    fi
    echo "    ${ACTUAL}"
fi

echo "PASS"
