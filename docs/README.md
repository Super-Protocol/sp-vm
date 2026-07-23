# Virtual Machine Attestation and Trust Infrastructure

## Purpose

This documentation explains how nodes in a trusted network prove the
authenticity of their execution environment before receiving network secrets
and being admitted to the Swarm. It covers:

- Intel TDX and AMD SEV-SNP hardware attestation;
- NVIDIA Confidential Computing GPU attestation;
- calculation and verification of the normalized `mrEnclave` measurement;
- bootstrap of the first virtual machine;
- enrollment of subsequent virtual machines;
- the PKI hierarchy, certificates, and `swarm key` distribution;
- creation and publication of reference measurements.

## Debug Networks

Separate `untrusted` networks are available for development and debugging.
They use a dedicated unsigned VM build in which some checks required for a
trusted network are disabled. Trusted and untrusted builds have different
network types and cannot join a network of the other type. The internal design
of untrusted networks is outside the scope of this documentation.

## Contents

1. [Architecture and trust model](01-architecture.md)
2. [First VM bootstrap](02-first-vm-bootstrap.md)
3. [Joining a subsequent VM](03-node-join.md)
4. [Intel TDX and AMD SEV-SNP measurements](04-vm-measurements.md)
5. [NVIDIA GPU attestation](05-nvidia-gpu-attestation.md)
6. [PKI architecture](06-pki.md)
7. [Reference measurements](07-reference-measurements.md)

## Terminology

| Term | Meaning |
|---|---|
| **TEE** | Trusted Execution Environment: an isolated, hardware-protected VM environment. |
| **Quote / report** | Hardware-signed evidence describing the TEE state and user data supplied to it. This documentation uses `quote` for TDX and `report` for SEV-SNP. |
| **Evidence** | A serialized set of proofs: a quote/report and required supporting data, such as the TDX event log. |
| **Launch measurement** | A measurement of the components involved in starting the VM. |
| **`mrEnclave`** | An internal normalized platform measurement used to match a running VM against an approved reference value. It is not a single hardware quote field. |
| **Reference measurement** | An `mrEnclave` approved by the owner of the trusted build. |
| **`reportData`** | Up to 64 bytes of user data cryptographically included in the CPU quote/report. |
| **Challenge** | An attestation request containing the TEE type, CPU evidence, and an NVIDIA token when a GPU is present. |
| **PKI Authority** | A certificate authority inside the trusted network that verifies challenges and issues node certificates. |
| **Swarm key** | A 32-byte symmetric key used for protected SwarmDB communication. |
| **Untrusted GPU** | A GPU that does not meet the confidential-compute memory requirements. |

## Two Evidence Classes

The attestation process uses two linked mechanisms:

1. **CPU TEE evidence** proves the authenticity of the hardware platform and
   contains VM launch measurements.
2. **NVIDIA GPU evidence** proves the state of the GPU, driver, and VBIOS. Its
   hash is included in CPU `reportData`, so CPU and GPU evidence cannot be
   substituted independently.

## Successful Attestation Criteria

For a VM with a GPU, a certificate is issued only when all of the following
conditions hold:

- the CPU quote/report is cryptographically valid;
- launch measurements are consistent with the evidence;
- the calculated `mrEnclave` is present in the trusted registry;
- CPU `reportData` is bound to the public key of the requested certificate;
- every detected GPU uses protected memory exclusively;
- the NVIDIA token is valid and bound to the same CPU quote/report;
- the NVIDIA policy passes and `dbgStat` is disabled for every GPU.

For a VM without a GPU, the NVIDIA portion is absent. The absence of a GPU is
not an error.

The first VM cannot contact a PKI Authority that does not yet exist. During
bootstrap, it validates its own hardware evidence locally and creates the root
CA. Subsequent nodes trust that root only when its calculated `mrEnclave` is
available in the trusted registry.
