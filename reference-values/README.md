# sp-vm Reference Values (CoRIM)

Every sp-vm release publishes its measurements as a **CoRIM** — a Concise
Reference Integrity Manifest (IETF RATS, CBOR, COSE_Sign1-signed) — so that a
relying party can appraise an sp-vm VM with its own Verifier (Intel Trust
Authority appraisal policies, a Veraison deployment, or anything else that
consumes reference values) **without trusting the Super Protocol PKI**.

The chain the published values close is:

```
sp-vm sources (git)
  │ reproducible build (README.md, "reproducibility test" sections)
  ▼
release artifacts: image, kernel, OVMF_AMD.fd, OVMF_TDX.fd, dm-verity root hash
  │ reference-values generator
  ▼
reference-values.json  +  sp-vm-<build>.corim.cbor (signed)  +  sp-vm-<build>.corim.json
  │ the customer's Verifier
  ▼
"this quote came from that release"
```

Super Protocol's own signed `mrEnclave` registry under `../signatures/` is
unchanged: the PKI join policy still uses it. The CoRIM adds the external,
standard format and republishes the same `mrEnclave` values next to the raw
hardware measurements, so the two can be cross-checked against each other.

## Published artifacts

Attached to the GitHub release of every build:

| File | Contents |
|---|---|
| `sp-vm-<build>.corim.cbor`   | the signed CoRIM: a COSE_Sign1 over the CBOR CoRIM |
| `sp-vm-<build>.corim.json`   | the same CoRIM as JSON, with the reference-values manifest embedded |
| `reference-values.json`      | the manifest on its own: every value in hex, with its provenance |

The public key the CoRIM is signed with, and the signing procedure, are in
[`keys/README.md`](keys/README.md).

## What is published, and where each value comes from

| Environment (CoMID `class.model`) | Registers | Source |
|---|---|---|
| `sp-vm`                            | `image`, `image-uncompressed`, `kernel`, `bios`, `bios-amd`, `bios-tdx`, `rootfs-verity-root-hash` | computed from the build output |
| `sp-vm-sev-snp:<profile>`          | `launch-digest`, `kernel-cmdline`, `mrenclave` | computed from the build output |
| `sp-vm-tdx`, `sp-vm-tdx-google`    | `mrtd`, `rtmr0`, `rtmr0-normalized`, `rtmr1`, `rtmr2`, `rtmr3`, `mrenclave`; `TDATTRIBUTES` as the measurement's raw value | a verified reference boot |
| `sp-vm-tdx-azure`, `sp-vm-sev-snp-azure` | `pcr4-normalized`, `pcr9-normalized`, `mrenclave`; the vm-configuration flags as the raw value | a verified reference boot |

`version` of every measurement is the sp-vm build id, so one CoRIM describes
exactly one release.

**Computed from the build output** means a pure function of the published
artifacts, reproducible by anyone who rebuilds the image — see
"Rebuild and measure yourself" below.

**A verified reference boot** means the register was read from a hardware quote
that a verifier accepted, because it cannot be predicted from the build:
`RTMR1`-`RTMR3` are produced by the boot chain and the Azure vTPM PCRs by the
Microsoft paravisor together with the boot chain. Those values are committed as
reference-evidence bundles under [`evidence/`](evidence/README.md), and the
generator re-derives and re-checks every one of them before publishing it. A
release without a bundle for a platform publishes no values for that platform;
the SEV-SNP and artifact values are always there.

### The kernel command line is part of the SEV-SNP measurement

The SEV-SNP launch digest covers the kernel command line, so a launch digest is
only meaningful together with the command line the VM was started with.
Super Protocol publishes one launch digest per command-line profile in
[`cmdlines/`](cmdlines/README.md); the CoMID environment is
`sp-vm-sev-snp:<profile>`, and `reference-values.json` records the full command
line of each profile verbatim.

An operator using a different command line gets a different launch digest and
must compute it themselves:

```bash
sev-snp-measure --mode snp --vcpus=1 --vcpu-type=EPYC-Milan \
    --ovmf=OVMF_AMD.fd --kernel=vmlinuz --append="<your command line>" \
    --output-format=hex
```

## Verifying a published CoRIM

Nothing but the signed CoRIM and the published public key is needed:

```bash
# 1. Download the release assets and the public key.
gh release download <build> --repo Super-Protocol/sp-vm \
    --pattern 'sp-vm-*.corim.cbor' --pattern 'reference-values.json'
curl -sO https://raw.githubusercontent.com/Super-Protocol/sp-vm/main/reference-values/keys/sp-vm-reference-values.pub.jwk

# 2. Verify the COSE_Sign1 signature.
#    `spref verify` needs only Python 3 and `cryptography`; it carries its own
#    CBOR and COSE code so that verification does not depend on this project's
#    other tooling.
git clone https://github.com/Super-Protocol/sp-vm && cd sp-vm
PYTHONPATH=reference-values python3 -m spref verify \
    --corim ../sp-vm-<build>.corim.cbor \
    --key ../sp-vm-reference-values.pub.jwk \
    --show
```

`--show` prints the decoded CoRIM using Veraison's `cocli`, which must be on
`PATH` for that flag:

```bash
go install github.com/veraison/corim/cocli@v1.1.2
cocli corim display --file sp-vm-<build>.corim.cbor --show-tags
```

## Rebuild and measure yourself

This is the procedure that makes the published values independent of
Super Protocol: rebuild the release from source, confirm the artifacts are
bit-identical, recompute the reference values from them, and compare with the
signed CoRIM.

Prerequisites: Docker with Buildx and the `security.insecure` entitlement,
Python 3.10+, Go 1.22+, roughly 60 GB of free disk.

```bash
# 0. Tooling.
git clone https://github.com/Super-Protocol/sp-vm && cd sp-vm
git checkout <the tag of the release>
python3 -m pip install -r reference-values/requirements.txt
go install github.com/veraison/corim/cocli@v1.1.2

# 1. Rebuild the image with the release's build tag. SP_VM_IMAGE_VERSION is an
#    input to the image, so it must be exactly the published build id.
docker buildx create --use --name insecure-builder \
    --buildkitd-flags '--allow-insecure-entitlement security.insecure'
docker buildx build -t sp-vm --allow security.insecure src \
    --output type=local,dest=./out \
    --build-arg SP_VM_IMAGE_VERSION=<build> \
    --build-arg SP_VM_BUILD_TYPE=release \
    --build-arg S3_BUCKET=builds-vm

# 2. Confirm the rebuild reproduced the published artifacts. Every artifact
#    except the compressed image is checked byte for byte; for the image the
#    uncompressed digest is the one that matters, because zstd settings are not
#    part of the measured state.
jq -r '.artifacts | to_entries[]
       | select(.key != "image")
       | "\(.value.sha256)  \(.value.filename)"' reference-values.json \
    | (cd out && sha256sum --check -)

jq -r '.artifacts.image | "\(.uncompressed_sha256)  \(.uncompressed_filename)"' \
    reference-values.json | (cd out && sha256sum --check -)

# 3. Recompute the reference values from your own build output.
PYTHONPATH=reference-values python3 -m spref generate \
    --build <build> \
    --artifact-dir out \
    --evidence-dir reference-values/evidence \
    --out-dir my-reference-values

# 4. Compare with what Super Protocol signed. The manifest must be identical;
#    only the CoRIM validity window differs, because it is a timestamp.
diff my-reference-values/reference-values.json reference-values.json
```

To check only the reproducibility of the build itself, without the reference
values, use the repository's own reproducibility tests
(`src/rootfs/tests/check_rootfs_reproducibility.sh`,
`src/image/tests/check_rootfs_verity_reproducibility.sh`,
`src/image/tests/check_disk_image_reproducibility.sh`).

A single measurement can also be reproduced without a full rebuild, from the
published artifacts:

```bash
# The normalised SEV-SNP launch digest of a command-line profile.
sev-snp-measure --mode snp --vcpus=1 --vcpu-type=EPYC-Milan \
    --ovmf=OVMF_AMD.fd --kernel=vmlinuz \
    --append="$(jq -r '.platforms["sev-snp"].cmdline_profiles["sp-vm-tools"].kernel_cmdline' reference-values.json)" \
    --output-format=hex
```

## Using the values in a Verifier

### Veraison

The CoRIM is produced and signed with `cocli`, the CLI of the Veraison
reference implementation, so a Veraison deployment decodes it without any
conversion:

```bash
cocli corim display --file sp-vm-<build>.corim.cbor --show-tags
cocli corim submit \
    --corim-file sp-vm-<build>.corim.cbor \
    --api-server "https://<veraison>/endorsement-provisioning/v1/submit" \
    --media-type "application/corim-unsigned+cbor; profile=\"https://superprotocol.com/corim/sp-vm/1\""
```

The CoRIM declares the profile `https://superprotocol.com/corim/sp-vm/1`.
Turning the stored endorsements into an appraisal verdict needs a Veraison
*scheme* for that profile; writing it is the sibling task "Verifier-side
integration: Intel Trust Authority + Vault policy and a Veraison scheme" of the
TACRA/TWI epic, not part of this format.

### Intel Trust Authority

ITA appraisal policies are Rego and pin the token claims directly. Substitute
the values of the `sp-vm-tdx` environment of the release (ITA policy V2 syntax;
V2 allows no comments, and the verdict rule must be called `match`):

```rego
import rego.v1

default match := false

match if {
    sp_vm_release
    tcb_up_to_date
}

sp_vm_release if {
    tdx := input.tdx
    tdx.tdx_mrtd == "<mrtd from reference-values.json>"
    tdx.tdx_rtmr0 == "<rtmr0>"
    tdx.tdx_rtmr1 == "<rtmr1>"
    tdx.tdx_rtmr2 == "<rtmr2>"
    tdx.tdx_rtmr3 == "<rtmr3>"
    tdx.tdx_is_debuggable == false
}

tcb_up_to_date if {
    input.tdx.attester_tcb_status == "UpToDate"
}
```

Notes that matter in practice:

* Pin `tdx_rtmr0`, not `rtmr0-normalized`. The normalised value is the
  Super Protocol construction that drops the dynamic boot events from `RTMR0`;
  an ITA token carries the raw register, which is what `rtmr0` in the CoRIM is.
  A relying party that wants the normalisation has to recompute it from the
  event log, outside ITA.
* `policy_ids` must be passed with the attestation request (or bound to the API
  key), and a token is issued even when a policy does not match unless
  `PolicyMustMatch` is set — the relying party must check
  `policy_ids_matched`.
* ITA has no AMD SEV-SNP attester type, so the `sev-snp` values of a release
  cannot be appraised through ITA. For SEV-SNP use a Verifier that accepts the
  launch digest directly (Veraison, or the Super Protocol verification path).
* ITA's documented policy claim allow-list is narrower than its claim table;
  `tdx_mrtd`, `tdx_rtmr0`-`tdx_rtmr3`, `tdx_mrsignerseam`, `tdx_is_debuggable`
  and `attester_tcb_status` are the safe set. Validate anything else with ITA's
  policy validator before relying on it.

## Generating and signing (maintainers)

```bash
# Unit tests.
cd reference-values && python3 -m unittest discover -s tests -t .

# End-to-end against a real build output.
SP_VM_ARTIFACT_DIR=/path/to/out SP_VM_BUILD=build-448-release \
    reference-values/tests/check_reference_values_e2e.sh

# Generate, sign, verify.
PYTHONPATH=reference-values python3 -m spref generate \
    --build build-448-release --artifact-dir out \
    --evidence-dir reference-values/evidence --out-dir rv
PYTHONPATH=reference-values python3 -m spref sign --in-dir rv --key sp-vm-reference-values.jwk
PYTHONPATH=reference-values python3 -m spref verify \
    --corim rv/sp-vm-build-448-release.corim.cbor \
    --key reference-values/keys/sp-vm-reference-values.pub.jwk \
    --expect-payload rv/sp-vm-build-448-release.corim-unsigned.cbor
```

`generate` is deterministic apart from the CoRIM validity window, which is why
`sign` is a separate command: the offline machine that holds the key
regenerates the CoRIM from the published artifacts, compares it byte for byte
with the unsigned asset and signs only that.

In CI, `.github/actions/reference-values` runs all three steps. It is called
from `build-sp-vm.yml` for every release and from `reference-values.yml` for a
re-publication, for instance once a TDX or Azure reference-evidence bundle has
been committed. Without the `REFERENCE_VALUES_SIGNING_JWK` secret the CoRIM is
published unsigned and the job warns instead of failing.

## Current coverage

| Platform | Status |
|---|---|
| `sev-snp` (QEMU / bare metal) | published, computed in CI for every release |
| build artifacts and dm-verity root hash | published, computed in CI for every release |
| `tdx`, `tdx-google` | published as soon as a reference-evidence bundle for the release is committed |
| `tdx-azure`, `sev-snp-azure` | as above |
| `arm-v9` | not covered |

Predicting `MRTD` and the normalised `RTMR0` from `OVMF_TDX.fd` in CI, instead
of reading them from a reference boot, is possible — `MRTD` is a function of
the TDX firmware alone — and would remove the reference boot from the TDX path.
It is deliberately not done here: a predicted measurement that has never been
compared with a real TD quote must not be signed and shipped to a customer's
Verifier. It becomes worth adding once a TDX reference host is available to
validate the prediction against.
