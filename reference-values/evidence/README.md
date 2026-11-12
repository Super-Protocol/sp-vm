# Reference-evidence bundles

Some reference values cannot be predicted from the build:

| Platform                       | Values                                   | Source |
|--------------------------------|------------------------------------------|--------|
| `sev-snp` (QEMU / bare metal)  | launch digest                            | computed in CI from the build artifacts |
| `tdx`, `tdx-google`            | `MRTD`, `RTMR0`-`RTMR3`                  | a reference boot |
| `tdx-azure`, `sev-snp-azure`   | vTPM `PCR4'`, `PCR9'`, vm-configuration  | a reference boot |

`MRTD` is a function of the TDX firmware alone, but `RTMR1`-`RTMR3` are
produced by the boot chain and the Azure vTPM PCRs are produced by the
Microsoft paravisor together with the boot chain. Neither can be derived from
the build output, so they are collected once per release from a VM started from
exactly that release and committed here as a bundle:

```
reference-values/evidence/<build>/<platform>.json
```

`spref generate --evidence-dir reference-values/evidence` picks up every bundle
for the build it is generating and adds the corresponding reference-value
triples to the CoRIM. A build with no bundle simply publishes fewer platforms;
the SEV-SNP and artifact values are always present.

## Collecting a bundle

1. Start a VM from the release on the target platform, with the kernel command
   line the reference value should cover.
2. Ask the Measurement API of the running VM for its evidence:

   ```bash
   curl -s "http://<VM-IP>:9180/v1/getMeasure" > measure.json
   ```

   The response carries `type`, the serialized `evidence` and `mrenclaveHex`
   (see `docs/04-vm-measurements.md`).
3. Verify that evidence with the normal verification path - a bundle must only
   ever be built from evidence a verifier has accepted.
4. Write the bundle below from the verified quote and event log. Record
   `mrenclave` exactly as the Measurement API reported it, and
   `evidence_sha256` as the SHA-256 of the base64-decoded `evidence` blob, so
   the published values stay traceable to the evidence they came from.

Nothing in a bundle is taken on trust. For a TDX bundle the generator replays
`rtmr0_event_log` and requires it to reproduce `rtmr0`, recomputes the
normalised `RTMR0` and the `mrEnclave`, and refuses the bundle unless the
`mrEnclave` matches. For an Azure bundle it replays the PCR4 and PCR9 events,
normalises them and recomputes `mrEnclave` from them and the vm-configuration
flags. A mistyped or altered register therefore cannot reach a signed CoRIM.

## Schema

`example-tdx.json` and `example-tdx-azure.json` in this directory are complete,
self-consistent bundles with made-up measurements (`build-000-example`). They
are checked by the unit tests, so they stay valid against the code.

### Common fields

| Field              | Description                                                   |
|--------------------|---------------------------------------------------------------|
| `schema`           | `https://superprotocol.com/schemas/sp-vm-reference-evidence/1` |
| `build`            | the sp-vm build id; must match the directory name              |
| `platform`         | `tdx`, `tdx-google`, `tdx-azure` or `sev-snp-azure`            |
| `collected_at`     | RFC 3339 timestamp of the reference boot                       |
| `collected_on`     | free text: host, provider, instance type, kernel command line  |
| `evidence_sha256`  | SHA-256 of the raw evidence blob the values were read from     |
| `mrenclave`        | `mrenclaveHex` from the Measurement API, lower-case hex        |

### `tdx`, `tdx-google`

| Field                       | Description                                           |
|-----------------------------|-------------------------------------------------------|
| `tdx.td_attributes`         | `TDATTRIBUTES` from the quote, 8 bytes of hex          |
| `tdx.mrtd`                  | `MRTD`, 48 bytes of hex                                |
| `tdx.rtmr0` ... `tdx.rtmr3` | `RTMR0`-`RTMR3` from the quote, 48 bytes of hex each   |
| `tdx.rtmr0_event_log`       | the full RTMR0 event list, in order: `{"type": "<TCG event type>", "digest": "<48 bytes of hex>"}` |

The event list must contain at least one `EV_EFI_PLATFORM_FIRMWARE_BLOB` or
`EV_EFI_PLATFORM_FIRMWARE_BLOB2` entry, because the normalised `RTMR0` is built
from those entries alone.

### `tdx-azure`, `sev-snp-azure`

| Field                       | Description                                           |
|-----------------------------|-------------------------------------------------------|
| `azure.vm_configuration`    | the vm-configuration flags as booleans: `secure-boot`, `tpm-enabled`, `console-enabled`, and on TDX also `interactive-console-enabled` and `filtered-vpci-devices-allowed` |
| `azure.event_log`           | the PCR4 and PCR9 events, in order: `{"pcr": 4, "type": "<TCG event type>", "digest": "<32 bytes of hex>", "data": "<hex, EV_EFI_ACTION and EV_SEPARATOR only>"}` |

`EV_NO_ACTION` events are dropped, and an `EV_EFI_ACTION` or `EV_SEPARATOR`
event is dropped when its digest is the SHA-256 of its own event data - which
is why those two event types must carry `data`.
