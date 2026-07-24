# First Virtual Machine Bootstrap

## Initial State

The first VM starts before the network's SwarmDB and PKI infrastructure have
been created:

```yaml
swarm_db:
  join_addresses: []

pki_authority:
  caBundle: ""
  servers: []
```

All three values must be empty at the same time. The detector writes the
`init` mode to `/etc/swarm/swarm-vm-mode`.

## Sequence

```mermaid
sequenceDiagram
    participant VM as First VM
    participant GPU as NVIDIA GPU/NRAS
    participant TEE as CPU TEE
    participant GEN as PKI chain generator
    participant DB as SwarmDB
    participant PKI as PKI Authority

    VM->>VM: Detect mode=init and trusted network
    VM->>VM: Detect TDX or SEV-SNP
    opt GPUs detected
        VM->>GPU: Check protected/unprotected memory
        VM->>GPU: Obtain token with nonce
    end
    VM->>TEE: Create evidence bound to key and GPU token
    GEN->>GEN: Verify CPU and GPU evidence integrity
    GEN->>GEN: Create root and specialized subroot CAs
    GEN->>GEN: Create first VM certificate
    VM->>VM: Generate swarm key
    VM->>DB: Store PKI material and swarm key
    DB->>PKI: Supply configuration and secrets
    PKI->>PKI: Start CA for enrollment of new VMs
```

## 1. Detecting the Hardware Environment

The CPU TEE type is detected automatically:

- `/dev/tdx_guest` identifies Intel TDX;
- `/dev/sev-guest` identifies AMD SEV-SNP;
- the absence of a supported device stops attestation.

The detected CPU type is written to `/etc/swarm/swarm-cpu-type`.

## 2. Creating Keys and the Challenge

When the VM has GPUs, GPU evidence is prepared before CPU evidence is created:

1. GPUs exposing unprotected memory are rejected;
2. a random nonce is generated;
3. an NVIDIA token is obtained;
4. SHA-256 is calculated over the serialized NVIDIA token;
5. the public-key hash and token hash are combined in CPU `reportData`.

The CPU quote/report therefore attests the VM environment, certificate key,
and the specific GPU token together.

## 3. Local Evidence Verification

Before creating the certificates, the generator verifies the hardware
evidence:

- for TDX, it verifies the DCAP quote and event-log integrity;
- for SEV-SNP, it verifies report authenticity and the required platform
  security properties, and reproduces the launch measurement;
- when a GPU is present, it verifies token binding, the NVIDIA verification
  results, and the absence of debug mode;
- the public-key hash in the verified `reportData` must match the key of the
  certificate being created.

This local verification confirms the cryptographic correctness and hardware
integrity of the reports. It does not compare the first VM's `mrEnclave` with
the trusted registry. Joining nodes perform that registry check later, before
accepting the root CA.

## 4. Creating the PKI

A root CA and two specialized subroot CAs are created:

- device enrollment;
- evidence signing.

A first-VM certificate signed by the device subroot is also created. The full
hierarchy is described in the [PKI chapter](06-pki.md).

The root certificate contains:

- the challenge type;
- `networkType=trusted`;
- serialized CPU TEE evidence.

The first-VM certificate also contains the challenge metadata and CPU evidence,
as well as verified GPU information when a GPU is present.

## 5. Creating and Storing the `swarm key`

The first VM generates one random 32-byte value, represented by 64 hexadecimal
characters. The file:

```text
/etc/swarm/swarm.key
```

is created with mode `0600` and is not overwritten.

After local SwarmDB starts, the bootstrap procedure stores:

- root and subroot certificates;
- their private keys;
- the PKI management token;
- the `swarm key`;
- the evidence-signing key.

PKI material is stored as `SwarmSecrets`. After a successful import, the
temporary `/etc/super/certs/swarm-init` directory is removed to avoid retaining
a second copy of private keys.

## 6. Starting the PKI Authority

The provisioning component obtains secrets from replicated state, writes them
to PKI Authority persistent storage, and creates a configuration containing:

- `networkType: trusted`;
- a unique `networkID`;
- allowed `tdx`, `tdx-google`, and `sev-snp` challenges;
- `mrEnclave` verification through the trusted registry;
- the `swarmKey` issued to attested nodes;
- an HTTPS endpoint on port `9443`.

After startup, the PKI Authority on the first VM becomes the enrollment point
for new nodes. Its addresses and CA bundle must be passed to joining VMs
together with the existing SwarmDB addresses.

## Bootstrap Result

Bootstrap is complete when the following exist:

- a trusted-network root CA containing CPU TEE evidence;
- device and evidence subroot CAs;
- a bootstrap-generated certificate for the first VM;
- the `swarm key`;
- a running PKI Authority;
- SwarmDB containing PKI secrets and network state.
