# Intel TDX and AMD SEV-SNP Measurements

## Purpose of `mrEnclave`

TDX and SEV-SNP use different hardware formats. The system converts them to a
32-byte `mrEnclave` identifier that:

- is deterministic for an equivalent trusted configuration;
- can be verified from hardware evidence;
- can be published as a reference value;
- does not depend on vCPU count, RAM size, or GPU presence.

`mrEnclave` is an application-protocol term. It must not be equated with only
TDX `MRTD`, SEV-SNP `MEASUREMENT`, or SGX `MRENCLAVE`.

This independence applies to the final `mrEnclave` calculated by the system. A
single reference value can therefore cover VMs started from the same trusted
build with different vCPU counts, RAM sizes, and with or without GPUs. The
underlying hardware evidence may still contain additional information about a
specific VM instance.

## Measurement API

Every VM runs the Measurement API service. It can be used to request the
calculated VM measurement and the evidence from which it was obtained:

```text
GET http://<VM-IP>:9180/v1/getMeasure
GET http://<VM-IP>:9180/api/v1/getMeasure
```

Both paths are equivalent.

The response contains:

```json
{
  "type": "<hardware evidence type>",
  "evidence": "<base64>",
  "mrenclaveHex": "<hex>"
}
```

The `type` field identifies the hardware evidence type. The API creates
evidence with a zero-filled 64-byte `reportData`; this evidence is intended for
measuring the running VM. It is not an enrollment challenge, where
`reportData` binds the certificate public key and, when present, the serialized
NVIDIA token.

## Intel TDX

### Input

The following TDX quote fields are used:

| Field | Size |
|---|---:|
| `TDATTRIBUTES` | 8 bytes |
| `MRTD` | 48 bytes |
| `RTMR0` | 48 bytes |
| `RTMR1` | 48 bytes |
| `RTMR2` | 48 bytes |
| `RTMR3` | 48 bytes |
| `REPORTDATA` | 64 bytes |

TDX evidence contains both the quote and the `RTMR0` event list, and they are
transmitted together. Each event entry contains only the event type and its
48-byte SHA-384 digest; raw event payloads and event logs for `RTMR1`–`RTMR3`
are not included. `mrEnclave` cannot be calculated without the `RTMR0` event
list.

### 1. Quote Verification

The DCAP verifier checks the quote signature and the Intel verification data
required to confirm that the quote was produced by a genuine TDX platform with
an acceptable security state.

Attestation continues only when the verifier reports success. An invalid
signature, missing or unusable verification data, an unacceptable platform
security state, or an internal verification error means that trust in the
quote cannot be established. In all such cases, the evidence is rejected.

### 2. RTMR0 Event Log Integrity

`RTMR0` is reconstructed from all entries in the transmitted list, starting
with 48 zero bytes:

```text
R₀ = 0x00 × 48
Rᵢ = SHA-384(Rᵢ₋₁ || eventDigestᵢ)
```

The fully reconstructed `Rₙ` is compared with quote `RTMR0`. A mismatch means
that the transmitted event list does not represent the hardware-attested
state.

`RTMR1`, `RTMR2`, and `RTMR3` are read directly from the verified quote and are
not reconstructed from event logs.

### 3. RTMR0 Normalization

For the final measurement, RTMR0 is calculated again using only:

```text
EV_EFI_PLATFORM_FIRMWARE_BLOB
EV_EFI_PLATFORM_FIRMWARE_BLOB2
```

All other event types are excluded. This reduces the effect of dynamic boot
events that do not belong to the selected firmware identity.

### 4. Final Formula

All fields are concatenated as binary arrays without text encoding or
delimiters:

```text
mrEnclave = SHA-256(
    TDATTRIBUTES ||
    MRTD ||
    normalizedRTMR0 ||
    RTMR1 ||
    RTMR2 ||
    RTMR3
)
```

The result is 32 bytes, or 64 characters in hexadecimal form.

The vCPU count, RAM size, and GPU presence are not passed to this formula as
separate parameters. In the normal flow, changing these resources does not
change the TDX fields used by `mrEnclave` or the normalized RTMR0 event set.
NVIDIA GPU attestation is performed separately and bound to CPU evidence
through `reportData`; GPU evidence is not part of `mrEnclave`.

### TDX Data Flow

![TDX measurement data flow](assets/tdx-data-flow.svg)
<!-- Mermaid source: assets/mermaid/tdx-data-flow.mmd -->

### Conditions That Reject TDX Evidence

- DCAP verification fails;
- the transmitted event list does not reproduce quote `RTMR0`;
- the calculated `mrEnclave` is absent from the trusted registry.

## AMD SEV-SNP

### Evidence Contents

SEV-SNP evidence transmits the original binary SNP report together with the
supporting fields required to verify and normalize its measurement:

- the original binary SNP report;
- the build identifier;
- the kernel command-line hash;
- the CPU signature;
- the vCPU count.

The build identifier, kernel command-line hash, CPU signature, and vCPU count
are part of the serialized evidence; they are not obtained separately by the
verifier.

### 1. Cryptographic Verification

The SNP report signature is verified using the platform VCEK certificate, AMD
CA chain, and certificate revocation lists (CRLs) provided through AMD KDS. The
verifier builds the chain to an AMD CA and confirms that the certificates
involved in verification have not been revoked.

### 2. TCB and Security Flag Verification

The `debugAllowed`, `ciphertextHiding`, `pageSwapDisabled`, and `snp` fields are
extracted from the SNP report and checked separately. These fields must have
the recommended values. Evidence is rejected if they do not.

### 3. Obtaining Build Artifacts

The build identifier is included in the supporting fields of SEV-SNP evidence.
When evidence is created, the value is extracted from the running VM kernel
command line.

The build identifier selects the matching OVMF image for download and the
published kernel and initrd hashes used to reproduce the launch measurement.

### 4. Verifying the Actual Launch Measurement

The SNP launch digest is reproduced from OVMF and the component hashes.
`cpuSig` and `cores` are transmitted as supporting evidence fields; they are
not extracted from the binary SNP report:

```text
expectedMeasure = ComputeLaunchDigest(
    OVMF,
    kernelHash,
    initrdHash,
    cmdLineHash,
    evidence.cpuSig,
    evidence.cores
)
```

The launch measurement algorithm is published and can be reproduced by the
verifier. The system uses a small fork of the
[Rust SEV-SNP measurement implementation](https://github.com/Super-Protocol/sp-sev)
that accepts the existing kernel and initrd hashes instead of the corresponding
files. This avoids downloading those files during verification.

The result is compared with the hardware `MEASUREMENT` in the report. A
mismatch stops attestation. The build identifier alone is therefore not proof:
the report contents must be reproducible from the published artifacts.

### 5. Normalization

After the actual VM is verified, the launch digest is recalculated for a
canonical configuration:

| Parameter | Normalized value |
|---|---|
| CPU | AMD EPYC Milan, family 25, model 1, stepping 1 |
| vCPU count | `1` |

The CPU signature is constructed from family, model, and stepping according to
CPUID encoding.

```text
singleCoreMeasure = ComputeLaunchDigest(
    OVMF,
    kernelHash,
    initrdHash,
    cmdLineHash,
    MILAN_CPU_SIGNATURE,
    1
)
```

The final normalized 32-byte `mrEnclave` is derived from
`singleCoreMeasure`.

The actual CPU signature and vCPU count are used only to verify that the SNP
report `MEASUREMENT` corresponds to the running VM. They are replaced with
canonical values in the final `mrEnclave`. RAM size and GPU presence are not
inputs to `ComputeLaunchDigest` or the final formula. The normalized SEV-SNP
`mrEnclave` therefore does not depend on vCPU count, RAM size, or GPU presence.

### SEV-SNP Data Flow

![SEV-SNP measurement data flow](assets/sev-snp-data-flow.svg)
<!-- Mermaid source: assets/mermaid/sev-snp-data-flow.mmd -->

### Conditions That Reject SEV-SNP Evidence

- SNP report cryptographic verification fails;
- the TCB fields or security flags do not have the recommended values;
- SEV-SNP evidence fields have an invalid format or size;
- the SEV-SNP build is unknown or unavailable;
- required build data or artifacts are unavailable;
- the calculated SEV-SNP launch digest does not match report `MEASUREMENT`.
