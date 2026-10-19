# Shared redaction fixtures — `sp.unit-health/v1`

Two artefacts, deliberately **real**, and deliberately **byte-identical in two
repositories**: here, for the `sp-vm` publishers, and in `tee-pki` for the
`:9180/v1/nodeHealth` endpoint's redaction tripwire (SUP-376 contract §4).

Both sides assert the same property: **nothing matching the token pattern
(≥40 base64/hex characters in a row) and no PEM marker ever reaches the
surface.** The anti-drift mechanism between the bash redactor and the
TypeScript tripwire is this shared fixture, not shared code — the two cannot
share an implementation, so they must at least fail on the same input.

A hand-written line does not satisfy this. Both SUP-372 redaction bugs were
invisible to synthetic fixtures and visible the moment a real artefact was fed
through:

- a 200-character line cap silently dropped every real `pki-sync-client` error
  line, because those measure 230-245 characters with pino's default fields —
  the one-line synthetic fixture was well under the cap;
- an 8-character head per redacted token leaked 200 uniformly-sampled
  characters of a real RSA private key, because a PEM body line is nothing but
  a token and the final body line is too short to be one at all.

## `private-key.pem`

A real RSA 2048 key, as a key really arrives:

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out private-key.pem

It is a throwaway key that has never been used for anything and exists only to
be fed through a redactor. What matters about it: 26 body lines of pure base64,
and a **short final body line** (24 characters) that no per-line token rule can
reach.

## `pki-sync-client-403.log`

A capture of what `pki-sync-client` really logs on the secrets-403 path — the
`http-403-unvalidated` classification's own input. Regenerate with:

    npm install pino
    NODE_PATH=./node_modules node capture-pki-sync-client-403.cjs

`capture-pki-sync-client-403.cjs` replays the exact sequence of log calls
`packages/pki-sync-client/src/sync-client.ts` makes for a 403 — including
`evaluateRetry`'s `http-status:403` reason (`:212`) and the non-retryable
verdict (`:495`, `:500`) — through the same logger the client uses
(`CommonPinoLog`: default `pino()`, one JSON object per line,
`.child(context).<level>(msg)`). Two details of the real shape that a
hand-written fixture would not have:

- the error lines land at **243-253 characters**, which is what defeated the
  first console line cap;
- the lines are **interleaved out of emission order**, because
  `CommonPinoLog.child()` constructs a new `CommonPinoLog` and therefore a new
  `pino()` destination with its own buffer. Each server's lines flush
  independently, so a tail of this log is not in call order.

Only `os.hostname()` is pinned (to `swarm-node-2`), so the fixture reads as a
swarm node instead of naming whichever machine captured it. The field set, the
line lengths and the interleaving are pino's own.
