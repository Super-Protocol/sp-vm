# The sp-vm Reference-Values key

The Reference Values of an sp-vm release are published as a COSE_Sign1-signed
CoRIM. The key that signs them is **not** part of the Super Protocol PKI: a
relying party that appraises an sp-vm release trusts this key for exactly one
statement — "these are the measurements of that release" — and nothing else.
It is deliberately separate from the key that signs the internal `mrEnclave`
registry in `../../signatures/`.

| Property       | Value                                                    |
|----------------|----------------------------------------------------------|
| Algorithm      | ECDSA P-384, COSE `ES384` (`-35`)                        |
| Private key    | offline; HSM or an air-gapped machine, never in CI       |
| Public key     | `sp-vm-reference-values.pub.jwk` in this directory        |
| Rotation       | a new file per key; old files are kept so old releases stay verifiable |

## What is in this directory

`sp-vm-reference-values.pub.jwk` — the public half of the current key, in JWK
format. This is the file `spref verify --key` and the CI verification step
read, and the one a customer downloads. **Until the key ceremony below has been
performed the file is absent**, the CI signing step emits a warning and the
published CoRIM is unsigned; nothing else about the pipeline changes.

## Key ceremony

Run on the offline machine (or against the HSM) that will hold the key, never
on a CI runner:

```bash
# 1. Generate the key. With an HSM, create the key in the HSM instead and
#    export only the public half as PEM.
openssl ecparam -genkey -name secp384r1 -noout -out sp-vm-reference-values.pem
chmod 400 sp-vm-reference-values.pem

# 2. Export the public half and commit it.
openssl ec -in sp-vm-reference-values.pem -pubout -out sp-vm-reference-values.pub.pem
PYTHONPATH=reference-values python3 -m spref jwk \
    --in sp-vm-reference-values.pub.pem \
    --out reference-values/keys/sp-vm-reference-values.pub.jwk \
    --public --kid sp-vm-reference-values-1

# 3. Produce the signing JWK. Keep it on the offline machine; the interim CI
#    signing mode below stores it as a repository secret.
PYTHONPATH=reference-values python3 -m spref jwk \
    --in sp-vm-reference-values.pem \
    --out sp-vm-reference-values.jwk --kid sp-vm-reference-values-1
```

Publish the fingerprint of the public key next to the download so it can be
checked out of band:

```bash
openssl ec -pubin -in sp-vm-reference-values.pub.pem -outform DER 2>/dev/null \
    | openssl dgst -sha256
```

## Signing: offline versus CI

`spref generate` and `spref sign` are separate commands for this reason. The
generate step is deterministic and needs no key, so the production target is:

1. CI generates `reference-values.json` and the unsigned CoRIM and publishes
   both as release assets.
2. The offline machine downloads the unsigned CoRIM, regenerates it from the
   same release artifacts, compares it byte for byte, signs it and the signed
   CoRIM is attached to the release.

Until that ceremony is in place, CI signs with the `REFERENCE_VALUES_SIGNING_JWK`
repository secret and immediately verifies the result against the committed
public key. The artifact format, the verification procedure and everything a
customer does are identical in both modes — only the location of the private
key differs.

## Rotation

Add the new public key as a new file, switch the signing key, and leave the old
public key in place: a CoRIM signed by a retired key must stay verifiable for
as long as the release it describes is in use. Re-signing old releases with a
new key is not required and not recommended, because it would change bytes that
customers may already have pinned.
