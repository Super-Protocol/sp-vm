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

## 7. When Synchronization Fails

`pki-authority-sync.service` makes **one bounded attempt per start**: the sync
call is cut off after 240 s and the unit's `TimeoutStartSec` is 300 s, so the
start job always finishes. The retry belongs to systemd
(`Restart=on-failure`, `RestartSec=60`, `StartLimitIntervalSec=0`), which keeps
it off the boot path — the node reaches `multi-user.target` and stays
diagnosable instead of waiting for an authority that may never sign it.

Every attempt publishes its verdict to `/run/sp-health/pki-authority-sync.json`,
in the `sp.unit-health/v1` record format (SUP-376):

```json
{
  "schema": "sp.unit-health/v1",
  "unit": "pki-authority-sync.service",
  "state": "failed",
  "terminal": true,
  "gate": true,
  "ttl_sec": 480,
  "attempt": 412,
  "exit_code": 1,
  "reason_class": "http-403-unvalidated",
  "reason": "the authority issued a certificate it will not accept (secrets 403)",
  "authority_servers": ["10.0.0.10:9443", "10.0.0.11:9443"],
  "attempt_log": "/run/sp-health/pki-authority-sync.log",
  "updated_at": "2026-10-19T17:04:11Z"
}
```

`state` is `attempting`, `ok` or `failed`. `reason` carries the per-attempt
detail; `reason_class` is the stable grouping key for the same failure across
attempts (`timeout`, `exit-<code>`, `signal`, `missing-client`,
`http-403-unvalidated`, `http-<code>-refused`), which is what a health
aggregator should match on — `reason` embeds the elapsed seconds and moves every
attempt. `/run` is tmpfs, so a reboot cannot leave a node looking synced before
it has synced again.

The other three fields exist because a reader **outside** the guest has to act
on them:

- **`terminal`** — true iff no retry of this unit can succeed, which is the
  difference between *not yet* and *will not*. Only the publisher can tell a
  403 from an `ECONNREFUSED`, so the classification lives here and an
  aggregator cannot infer it. The terminal set is `http-403-unvalidated`,
  `http-400-refused` / `http-401-refused` / `http-422-refused`, and
  `missing-client`. Everything else stays non-terminal: `timeout`,
  `network-code:*`, `exit-<code>`, every 5xx, and — deliberately — **every
  other 4xx**.

  The set is an explicit list rather than a 4xx range because "every authority
  will refuse this node for the same reason" is only true of some of them. A
  malformed, unauthenticated or unvalidated client certificate is a property
  this node carries to every authority in the list. A `404` from an authority
  that predates the route is a property of the *cluster*, and version skew is
  routine — publishing `terminal: true` for it would tell an operator to
  replace a healthy node. The asymmetry sets the default: a wrong
  `terminal: true` ends a wait that should have continued, while a wrong
  `terminal: false` costs retries that are already bounded and already read as
  `degraded`. SUP-370 was 25 hours of waiting on a condition that would never
  clear, and `terminal` is the fact that would have ended it — which is exactly
  why it must never be wrong in the other direction;
- **`ttl_sec`** — twice the script's own bounded attempt (480 s at the default
  240 s attempt). A publisher killed by `TimeoutStartSec` leaves
  `state: attempting` on disk forever, and a reader that trusted it would
  report "still booting" indefinitely — SUP-370 reproduced at the reporting
  layer. Past `updated_at + ttl_sec` the record is **stale**, and stale is a
  verdict, not silence. A `failed` + `terminal` record never goes stale: `/run`
  is tmpfs, so it cannot outlive its boot;
- **`gate`** — whether the node's ability to serve depends on this unit. Without
  certificates and without a swarm key, `swarm-db`, `swarm-node` and
  `swarm-services` all stay down, so this one is `true`.

### The secrets 403 is terminal, and only this layer can say so

An `idHex` mismatch does **not** refuse the certificate: the authority sets
`validated = false`, logs the mismatch at `warn`, and issues the certificate
anyway, just without the challenge-validated extension. The refusal lands at the
**second** hop — `POST /api/v1/secrets/get` returns
`403 Certificate is missing challenge validation extension`. 403 is not in
`pki-sync-client`'s retryable status set (`{429, 502}`), so the client itself
concludes that no retry can succeed, logs that verdict, and stops.

Until SUP-376 the wrapper published only `exit_code: 1, reason_class: exit-1`,
destroying a fact the guest already had. It now reads the client's own
non-retryable verdict out of the attempt log and publishes
`reason_class: http-403-unvalidated` with `terminal: true` — and the console
block says the failure is terminal instead of reassuring the operator that
systemd will retry. Only the three-digit status code crosses out of the log; the
line itself is third-party text and stays where it was.

### `reason` is composed, never captured

Every `reason` and `reason_class` is built from a publisher-authored template
plus numbers. Captured client output reaches the console tail and
`attempt_log` and nothing else. This is a **rule of the format**, not an
accident of the current call sites: the `:9180` endpoint that serialises these
records to an unauthenticated port keeps a redaction tripwire, but that tripwire
is a backstop on an input that is already safe — the trust boundary is here, at
the writer. `src/rootfs/tests/test_pki_authority_sync.sh` enforces both halves:
no `write_state` call site may interpolate a command substitution, and every
record the suite produces must carry a `reason` matching one of the templates.

`authority_servers` and `attempt_log` stay in the file deliberately — the
private PKI topology and a runtime-local path, both useful on the console and
neither fit to leave the node. The endpoint drops them by **allowlist** rather
than by trusting this writer to omit them.

**Nothing in `pki-vm-measurements` exposes this file off the node yet** —
`:9180/v1/nodeHealth` is the `tee-pki` half of SUP-376 — so until that ships it
is reachable only from inside the guest, in practice on a debug image over SSH.

On a `-release` image there is no SSH and no readable journal, so **the console
is the only channel**, and a failure is written there with the authority it
tried and the tail of the attempt's own output:

- the full block is printed for the first 3 attempts, again whenever the failure
  changes **kind** (`reason_class`, not the rendered `reason` — keying on the
  text makes every attempt look new, because the elapsed seconds move), and then
  once every 60 attempts (hourly at `RestartSec=60`); in between a single
  `still failing (attempt N)` line keeps the outage visible. The console is a
  bounded shared buffer — Azure boot diagnostics and nova `console-log` both keep
  only a tail — and an unthrottled block would push the original boot output out
  of the very logs collected as forensics: measured at 4.06 MB against 0.20 MB
  over a 25-hour outage. The journal keeps every block, and the health file is
  per-attempt regardless;
- key-shaped **tokens** are redacted out of a line rather than the line being
  dropped, so the message around them survives. A run of 40+ characters, **or
  20+ hex pairs separated by colons or spaces**, is treated by shape:
  - **hex** keeps a short head — `<329abfac... 64-char token redacted>` — which
    is what makes a CA fingerprint or an `mrEnclave` comparable against the
    authority's. A CA mismatch is the common root cause, so that token is the
    most useful thing on the console;
  - **base64** is suppressed with no head — `<64-char token redacted>`. The head
    of a secret was never diagnostic, and a PEM body line is nothing *but* a
    token: 8 characters from each of 25 body lines is 200 uniformly-sampled
    characters of a private key;
  - **delimited hex** — `17:F2:A7:7C:…` or `de ad be ef …` — is treated as hex
    and keeps a head. It needs its own rule because a separator every two
    characters means there is no 40-character run in the line at all: a
    32-pair SHA-256 fingerprint is 95 characters and was passing through
    whole. The floor of 20 pairs sits above a MAC address (6 pairs), a
    4-hex-group IPv6 address, a `host:port` and a UUID, all of which are
    diagnostic and must survive. Found by running the `tee-pki` half of the
    shared fixture through this redactor, which is what the shared fixture is
    for;
- a whole **PEM block** is suppressed, `-----BEGIN` through `-----END`, not just
  its header. The last body line of a key is short enough not to be a token at
  all, so no per-line rule can reach it. A block whose `-----BEGIN` has already
  scrolled out of the tail window is detected by its `-----END`, and a block
  with no `-----END` inside the window suppresses everything after it — losing
  the rest of the tail is the right trade against leaking a key. A line that
  merely quotes a marker inside a message is dropped on its own and does not
  open a block. Labels may contain `-`, as RFC 7468 allows: a label the matcher
  rejected would leave the block unopened and the short final body line would
  print in full;
- the 2000-character line cap is only a bound on how much one line may take from
  the console, **not** a security control — the shape rules above are. It matters
  that it stays well clear of the real lines: `pki-sync-client` logs one
  default-pino JSON object per line and its error lines run 230–245 characters,
  so a cap near that length drops precisely the lines that diagnose the node.

While synchronization keeps failing, `swarm-db`, `swarm-node` and
`swarm-services` stay down and `:9443` never opens, exactly as before. The
difference is that boot completes and the node says why. When a later attempt
succeeds, the unit starts those three services itself: their boot-time start
jobs died with the failed dependency, and `Restart=` cannot revive a unit whose
start job never ran.
