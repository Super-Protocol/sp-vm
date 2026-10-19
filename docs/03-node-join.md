# 3. Joining a Subsequent Virtual Machine

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

![Node join sequence](assets/node-join.svg)

## 1. Root CA Verification Before Enrollment

The self-signed root certificate is extracted from `caBundle`. Providing
multiple self-signed root certificates is an error. The certificate extensions
referenced in the checks are described in
[Certificate Extensions and OIDs](06-pki.md#certificate-extensions-and-oids).
The client then checks that:

1. the network-type extension equals `trusted`;
2. the root contains CPU TEE evidence of a supported hardware type: `tdx`,
   `tdx-google`, `tdx-azure`, `sev-snp`, or `sev-snp-azure`;
3. the quote/report signature and manufacturer verification data confirm
   platform authenticity and an acceptable security state;
4. a normalized `mrEnclave` can be calculated from the evidence;
5. the calculated `mrEnclave` is among the values allowed by the trusted
   registry.

A root certificate with `network type=untrusted` or with `untrusted` evidence
is rejected and cannot be used to join a trusted Swarm.

This confirms that the configured root CA was created inside an approved
confidential VM. Only then does the client contact the PKI Authority.

After receiving a response, the PKI client compares the cryptographic SHA-256
fingerprint of the returned root certificate with the root from the configured
`caBundle`. This prevents an unnoticed substitution of the trust root.

## 2. Creating the Node Key

The key pair is generated locally. The private key is never sent to the PKI
Authority. The challenge includes the SHA-256 hash of the public key. The
Authority compares it with the first 32 bytes of `reportData` extracted from
the verified CPU quote/report.

This proves possession of the corresponding private key: evidence cannot be
reused to request a certificate for a different key.

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
6. `mrEnclave` is among the values allowed by the trusted registry;
7. when an NVIDIA token is present, its hash, mandatory NVIDIA verification
   results, and the absence of debug mode are checked;
8. `networkID` matches the value configured for the current Swarm.

If any mandatory check fails, a certificate carrying the
[successful-attestation marker](06-pki.md#certificate-extensions-and-oids) is
not issued, so the request cannot be used to obtain `swarmKey`. Normal
trusted-node enrollment requires the entire sequence to pass.

## 5. Certificate Issuance Result

After successful validation, the PKI Authority issues a VM certificate
containing:

- the challenge type;
- the challenge ID (`mrEnclave`);
- CPU TEE evidence;
- the server-added successful-attestation marker;
- NVIDIA GPU information when GPU evidence was supplied.

The corresponding extensions are listed in
[Certificate Extensions and OIDs](06-pki.md#certificate-extensions-and-oids).

The client stores:

```text
/etc/super/certs/vm/vm_key.pem
/etc/super/certs/vm/vm_cert.pem
/etc/super/certs/vm/vm_ca.pem
```

`vm_cert.pem` contains the VM certificate and intermediate certificates;
`vm_ca.pem` contains the root CA.

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
4. identifies the VM certificate in the chain and requires its
   successful-attestation marker described in
   [Certificate Extensions and OIDs](06-pki.md#certificate-extensions-and-oids);
5. requires a non-empty list of requested secrets;
6. obtains `swarmKey` from configured storage and confirms that it exists.

A request without a client certificate, with an invalid chain, or without the
[successful-attestation marker](06-pki.md#certificate-extensions-and-oids) is
rejected. A TLS connection alone is therefore insufficient: the secret is
available only to a node holding a certificate issued after successful
challenge validation.

The client stores the received `swarmKey` in:

```text
/etc/swarm/swarm.key
```

The SwarmDB configuration is generated afterwards. A system dependency
prevents SwarmDB from starting before PKI synchronization succeeds. A node
without a certificate and `swarm key` therefore cannot join the SwarmDB
cluster through the normal flow.

## 7. Node Health: the Positive Witness that this Node Serves

Every bring-up unit publishes its own verdict to `/run/sp-health/<unit>.json` in
the `sp.unit-health/v1` format, and `:9180/v1/nodeHealth` aggregates the
directory. There is no central writer, so a unit that is dead cannot lie by
omission, and `/run` is tmpfs, so the whole surface is per-boot by construction.

**`/run/sp-health` holds records only — one `*.json` per unit.** The endpoint
enumerates this directory on an unauthenticated port, so every non-record file
in it is one filter bug away from being served, and a publisher's scratch state
is the worst possible neighbour: `pki-authority-sync.log` is raw, unredacted
client output — the same file that carried the leaked key in SUP-372. The
endpoint does filter to regular `*.json` files, but that should be a second line
of defence rather than the only one. Scratch state belongs in the publisher's
own `/run/<unit>/` directory, which is where `sp-node-serving-probe` keeps its
budget sentinel. Moving `pki-authority-sync`'s log and attempt counter out is
the follow-up that converges the three writers of this format.

`sp-health-publish` is the single writer of that format. It validates everything
it is given — the state must be `attempting`, `ok` or `failed`; `ttl_sec` must be
a positive number of seconds; `terminal` is only meaningful on a failure; a
record name is a file name and never a path — because a typo in a caller would
otherwise reach an unauthenticated port as an unparseable record. And `reason`
is **composed by the publisher, never captured** from a tool's output: that rule
is what lets the endpoint serialise these records with only a redaction tripwire
as a backstop rather than a second redactor with its own blind spots.

### `node-serving` is the only source of `serving`

Every other publisher reports a **gate** — something that must not have failed.
No gate, and no combination of gates, is evidence that the node serves:
`pki-authority-sync` can report `ok` while `swarm-node` is down, and a departed
node's gates all stay `ok` forever. So `sp-node-serving.timer` runs
`sp-node-serving-probe` every 30 s, probing from loopback exactly what the host
probes from outside:

1. `https://127.0.0.1:9443/api/v1/pki/certs/ca` returns a PEM — unauthenticated,
   the same call `cluster.sh`'s `fetch_ca` makes, so it answers only once
   `pki-cert-init`, `pki-authority-sync` and the PKI service have all finished;
2. `http://127.0.0.1:4001/nodes` is 2xx and lists this node — the same payload
   and the same match as `spvm_cloud.py`'s `parse_membership`, so it answers only
   once SwarmDB, the host agent and `swarm-node` are up and gossip has converged.

Both must pass. A CA with no membership entry is a node that is Ready but not
serving; a membership entry with no CA is a node that gossips but cannot serve a
request.

It publishes **two booleans and one status word from a closed set** —
`ca_ok`, `membership_ok`, and a `reason_class` of `serving`, `ca-unavailable`,
`membership-absent` or `no-local-evidence`. Never a name, an address, a port or
the member list: `:9180` is plain HTTP on a port opened with no source
restriction, and this record would otherwise be the only place on the surface
carrying a membership list.

Three numbers, all chosen here rather than in the contract:

| value | choice | why |
|---|---|---|
| timer interval | **30 s** | matches `pki-vm-measurements-healthcheck.timer`, the other thing on this node polling a local port, and is comfortably under any host-side poll period. Two bounded loopback calls every 30 s costs nothing. |
| `ttl_sec` | **60 s** | twice the **timer interval**. For a repeating publisher the ttl bounds the gap between writes, not the length of one attempt. `OnUnitActiveSec` measures from the previous activation, so a write lands every 30 s while the probe completes — and it is capped at 5 s per call with `TimeoutStartSec=20` as a backstop. The only way to reach 60 s between writes is a probe that gets killed by that backstop, and a record that then reads as stale is the correct verdict for a probe that is not completing. |
| bring-up budget | **1800 s** | how long the node may legitimately take to reach `serving` before `attempting` becomes `failed`. The slowest honest path is the 1200 s GPU readiness barrier *before* `pki-cert-init` even starts, plus PKI sync, SwarmDB, `swarm-node` and gossip convergence — call it 20 + 10 minutes. Shorter, and every GPU node reports a failure while it is simply booting. |


The budget is measured from a sentinel in `/run/sp-node-serving/first-run`,
written on the first run since boot. It is validated by **content**, not
existence, and rewritten whenever the content is unusable — empty, non-numeric,
or dated in the future. That matters more than it looks: testing existence
instead holds the start time at *now* on every run, so the elapsed time is
always 0, `failed` is unreachable, and the record stays `attempting` while being
rewritten every 30 s and therefore never going stale either. The endpoint cannot
catch that one; the rollup simply reads `booting` forever — SUP-370's
never-clearing condition, reproduced by the code meant to report it. A truncated
sentinel is not hypothetical, since the write truncates before it writes. And a
sentinel dated in the future is ordinary rather than corrupt — chrony steps the
clock during boot — so the budget restarts instead of freezing.
The verdict is never `terminal`. This unit is a witness, not an authority on
impossibility: a node can start serving at any later point, and the record flips
straight back to `ok` when both probes pass. The verdicts that end a wait come
from the gates that know they cannot be retried — `pki-authority-sync`'s
`http-403-unvalidated`, or the GPU barrier's `fabricmanager-timeout`.

The probe is ordered `After=swarm-node.service` but deliberately does **not**
require or want it. A dependency would silence the probe in exactly the state it
exists to describe. For the same reason `pki-vm-measurements`, which serves
`:9180`, no longer depends on the GPU readiness barrier — see
[the barrier's own section](05-nvidia-gpu-attestation.md#why-9180-is-not-behind-the-barrier).
