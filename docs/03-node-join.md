# Joining a Subsequent Virtual Machine

## Input

A joining VM must receive a consistent set of parameters:

```yaml
swarm_db:
  join_addresses:
    - "10.0.0.10:3306"

pki_authority:
  caBundle: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  servers:
    - "10.0.0.10:9443"
```

The values illustrate the structure only. Actual addresses and certificates
are supplied by the environment operator. When all three field groups are
populated, the VM selects `normal` mode. SwarmDB addresses are also used as
additional PKI endpoints on port `9443` when their hosts are not already
listed in `pki_authority.servers`.

## Join Sequence

```mermaid
sequenceDiagram
    participant VM as New VM
    participant REG as Trusted registry
    participant GPU as NVIDIA GPU/NRAS
    participant PKI as PKI Authority
    participant DB as SwarmDB

    VM->>VM: Validate configured CA bundle
    VM->>VM: Extract root CA and network type
    VM->>VM: Validate root CA CPU evidence
    VM->>VM: Calculate root CA mrEnclave
    VM->>REG: Retrieve mrEnclave signature
    REG-->>VM: Signature
    VM->>VM: Verify signature with trusted key
    opt VM contains NVIDIA GPU
        VM->>GPU: Validate GPU and obtain token
    end
    VM->>VM: Create key and CPU/GPU challenge
    VM->>PKI: Request certificate
    PKI->>PKI: Validate CPU quote/report and mrEnclave
    PKI->>PKI: Validate publicKeyHash
    opt Challenge contains NVIDIA token
        PKI->>PKI: Validate tokenHash and NVIDIA policy
    end
    PKI-->>VM: Certificate + CA chain
    VM->>PKI: Request swarmKey over protected channel
    PKI-->>VM: swarmKey
    VM->>DB: Start node with certificate and swarmKey
```

## 1. Root CA Verification Before Enrollment

Exactly one self-signed root is extracted from `caBundle`. The client then
checks that:

1. the network-type extension is present and equals local `trusted`;
2. the root contains CPU TEE evidence;
3. the quote/report signature and manufacturer collateral are valid;
4. a normalized `mrEnclave` can be calculated from the evidence;
5. a signature for `mrEnclave` is found in the trusted registry;
6. the signature is verified with the embedded public key.

This confirms that the configured root CA was created inside an approved
confidential VM. Only then does the client contact the PKI Authority.

After receiving a response, the PKI client also verifies that the SHA-256
fingerprint of the returned chain root matches the root from the configured
`caBundle`.

## 2. Creating the Node Key

The key pair is generated locally. The private key is never sent to the PKI
Authority. The challenge includes the SHA-256 hash of the public key. The
Authority compares it with the first 32 bytes of `reportData` extracted from
the verified CPU quote/report.

This provides proof of possession: evidence cannot be reused to request a
certificate for a different key.

## 3. Adding GPU Evidence

Without a GPU, the client creates a CPU-only challenge. When GPUs are detected:

- every display GPU passes the local confidential-memory check;
- an NVIDIA token is obtained with a fresh nonce;
- the token hash is placed in the second half of CPU `reportData`;
- the token itself is sent alongside CPU evidence.

The detailed algorithm is described in the
[NVIDIA GPU chapter](05-nvidia-gpu-attestation.md).

## 4. PKI Authority Checks

The Authority performs one ordered validation sequence:

1. the challenge type is allowed by the trusted-network configuration;
2. the CPU quote/report hardware signature is valid;
3. the TDX event log is consistent or the SEV-SNP launch digest is reproduced;
4. `mrEnclave` is extracted;
5. the public-key hash is verified;
6. `mrEnclave` is checked against an allowing rule and trusted signature;
7. when an NVIDIA token is present, its hash, policy, and `dbgStat` are checked;
8. `networkID` is checked to prevent use of the challenge in another Swarm.

If any mandatory check fails, the certificate is not considered validated.
Normal trusted-node enrollment requires the entire sequence to pass.

## 5. Certificate Issuance Result

After successful validation, the PKI Authority issues a VM certificate
containing:

- the challenge type;
- the challenge ID (`mrEnclave`);
- CPU TEE evidence;
- the validated marker;
- NVIDIA GPU information when GPU evidence was supplied.

The client stores:

```text
/etc/super/certs/vm/vm_key.pem
/etc/super/certs/vm/vm_cert.pem
/etc/super/certs/vm/vm_ca.pem
```

`vm_cert.pem` contains the leaf and intermediate chain; `vm_ca.pem` contains
the root CA.

> Note: in the current implementation, this certificate material is used by
> the PKI sync client to obtain `swarmKey`. After synchronization completes,
> it is not used by other node components.

## 6. Obtaining the `swarm key`

The client calls the PKI Authority secrets API over HTTPS and presents the
issued certificate. Before releasing the secret, the Authority:

1. rejects requests not received over HTTPS;
2. extracts the client certificate chain from the TLS connection;
3. validates the chain signatures and integrity against the current network
   root CA;
4. identifies the leaf certificate and requires its successful-attestation
   marker;
5. requires a non-empty list of requested secrets;
6. obtains `swarmKey` from configured storage and confirms that it exists.

A request without a client certificate, with an invalid chain, or without the
successful-attestation marker is rejected. A TLS connection alone is therefore
insufficient: the secret is available only to a node holding a certificate
issued after successful challenge validation.

The response carries `swarmKey` in base64. The client decodes and stores it in:

```text
/etc/swarm/swarm.key
```

The SwarmDB configuration is generated afterwards. A system dependency
prevents SwarmDB from starting before PKI synchronization succeeds. A node
without a certificate and `swarm key` therefore cannot join the gossip network
through the normal flow.
