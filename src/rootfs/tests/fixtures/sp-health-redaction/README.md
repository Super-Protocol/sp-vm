# Shared redaction fixtures — `sp.unit-health/v1`

Four artefacts, deliberately **real**, and deliberately **byte-identical in two
repositories**: here, for the `sp-vm` publishers, and in `tee-pki` at
`packages/pki-vm-measurements/src/__fixtures__/` for the
`:9180/v1/nodeHealth` endpoint's redaction tripwire (SUP-376 contract §4).

| file | origin | sha256 |
|---|---|---|
| `private-key.pem` | `sp-vm` | `60a42415c442d860afc40512621dc8032e419ba3d715951378988b92856bbb5f` |
| `pki-sync-client-403.jsonl` | `sp-vm` | `5cbb9044f3c7e31ef8fe68b3e8f466880c96011d58823416beb7281c41e2add4` |
| `openssl-genpkey-rsa2048.pem` | `tee-pki` | `5eb789201347344afd5c4ca965b3579ffaac47d39b60977ef89da5b4ad1373eb` |
| `pki-sync-client-pino.jsonl` | `tee-pki` | `b7de94e008683232908754469ed72c943ddb986b7a4660ea6934e7ebe9ab67a3` |

**Both sides assert the same property on all four: nothing matching a token
shape and no PEM marker reaches the surface, and nothing diagnostic is
dropped.** The two repos cannot share an implementation — the redactor is bash
here and a TypeScript tripwire there — so these bytes are the anti-drift
mechanism instead.

## Copy, never regenerate

The first attempt at this drifted immediately: both repos generated their own
pair in parallel, and both READMEs then asserted a byte-identity that was false.
That is worse than having no mechanism at all, because §4 reads as satisfied on
both sides while each redactor is pinned only by its own capture.

So the rule is **the union, not a pick**, and copying in both directions:

```sh
# from tee-pki into here
git -C ../../../../../tee-pki show \
    origin/feature/SUP-376-node-health-endpoint:packages/pki-vm-measurements/src/__fixtures__/openssl-genpkey-rsa2048.pem
```

If any of these bytes changes, change it in both repos and fix **both** sha256
tables in the same commit. `test_pki_authority_sync.sh` guards the properties
each capture exists for, so a silent replacement with a weaker artefact fails
the suite rather than passing it.

## Why real artefacts, and not one hand-written line

Both SUP-372 redaction bugs were invisible to synthetic fixtures and visible the
moment a real artefact went through:

1. a 200-character line cap silently dropped every real `pki-sync-client` error
   line, because those measure 230-245 characters with pino's default fields —
   the one-line synthetic fixture was well under the cap;
2. an 8-character head per redacted token leaked 200 uniformly-sampled
   characters of a real RSA private key, because a PEM body line is nothing but
   a token and the final body line is too short to be one at all.

And the union has now paid for itself in **both** directions, which is better
evidence for the mechanism than any argument for it:

- running `tee-pki`'s `pki-sync-client-pino.jsonl` through this repo's
  `redact()` found a colon-delimited digest passing through whole — fixed here,
  see that file below;
- running this repo's `private-key.pem` and that capture's own digest through
  the TypeScript tripwire found the symmetric pair, both live there until
  SUP-376 round 3: the colon-delimited digest (same hole, same constant) and the
  24-character final PEM body line, which that side cannot suppress as a block
  because a projected `reason` is one string with no block around it. It matches
  the padding instead. See
  `packages/pki-vm-measurements/src/__fixtures__/README.md` in `tee-pki`.

## The two keys

`private-key.pem` and `openssl-genpkey-rsa2048.pem` are both throwaway RSA 2048
keys that certify nothing and are trusted by nothing:

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out <file>

Each is 26 body lines of pure base64 with a **24-character final body line** —
short enough that no per-line token rule can reach it, which is why the block
has to be suppressed as a block. Two keys rather than one so that neither
repo's redactor has only ever seen the key its own author generated.

## `pki-sync-client-403.jsonl` — the firing path

A capture of what `pki-sync-client` logs on the **secrets-403** path, which is
the `http-403-unvalidated` classification's own input. Regenerate with:

    npm install pino
    NODE_PATH=./node_modules node capture-pki-sync-client-403.cjs

`capture-pki-sync-client-403.cjs` replays the exact sequence of log calls
`packages/pki-sync-client/src/sync-client.ts` makes for a 403 — including
`evaluateRetry`'s `http-status:403` reason and the non-retryable verdict —
through the same logger the client uses (`CommonPinoLog`: default `pino()`, one
JSON object per line, `.child(context).<level>(msg)`). Two details of the real
shape that a hand-written fixture would not have:

- the error lines land at **243-253 characters** (longest line 284), which is
  what defeated the first console line cap;
- the lines are **interleaved out of emission order**, because
  `CommonPinoLog.child()` constructs a new `CommonPinoLog` and therefore a new
  `pino()` destination with its own buffer. Each server's lines flush
  independently, so a tail of this log is not in call order.

Only `os.hostname()` is pinned (to `swarm-node-2`), so the fixture reads as a
swarm node instead of naming whichever machine captured it. The field set, the
line lengths and the interleaving are pino's own.

## `pki-sync-client-pino.jsonl` — the non-firing path, and the shape it exposed

A capture of a real `pki-sync-client` run against a real PKI authority on the
`untrusted` challenge, produced in `tee-pki` by
`scripts/fixtures/capture-pki-sync-client-log.ts`. It ends in a **successful**
sync, which makes it the *non*-firing input: every diagnostic line in it must
pass through unchanged. That is the other half of the job, and the half
SUP-372's first regression broke.

It also found a live hole in this repo's `redact()`, which is the best argument
for the union there is. Its `rootFingerprint256` / `trustedRootFingerprint256`
fields carry a SHA-256 fingerprint written as 32 **colon-separated** hex pairs:

    17:F2:A7:7C:75:9D:F0:84:…:1E:44:CC

That is 95 characters with **no 40-character run of `[A-Za-z0-9+/=]` anywhere in
it**, so `token_min_chars` never saw it and it reached the console whole. A root
CA fingerprint is not itself a secret, but the *shape* is: anything a tool
prints with `openssl -fingerprint` or `xxd` spacing arrives this way, and the
guarantee is supposed to be about shape rather than about which field happened
to carry it. `redact()` now treats 20+ delimited hex pairs as a hex token and
keeps a comparable head. A MAC address (6 pairs), a 4-hex-group IPv6 address, a
`host:port` and a UUID all stay below that floor and survive — asserted by test,
because a rule that eats the diagnosis is the regression this fixture exists to
prevent.

Its longest line is 694 characters, well clear of `max_line_chars`.
