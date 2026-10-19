#!/usr/bin/env bash

# SUP-375: sp-boot-attempt.sh is the shared half of the fix - one bounded
# attempt, and a verdict that reaches an operator who has no SSH and no readable
# journal. Three units depend on both properties, so both are pinned here rather
# than once per unit.
#
# The console-discipline and key-material guards are the ones carried over from
# test_pki_authority_sync.sh (SUP-372): the console is a bounded shared buffer
# that Azure boot diagnostics and nova console-log keep only a tail of, and
# /dev/console on a confidential VM is outside the TEE boundary while the tail
# it prints is somebody else's debug output.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_BOOT_ATTEMPT_TEST_INSTALLED_ROOT:-}" ]]; then
    bin_dir="$SP_BOOT_ATTEMPT_TEST_INSTALLED_ROOT/usr/local/bin"
else
    bin_dir="$repository_root/src/rootfs/files/configs/usr/local/bin"
fi
runner="$bin_dir/sp-boot-attempt.sh"

test_root="$(mktemp -d -t sp-boot-attempt.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$runner" ]] || fail "sp-boot-attempt.sh is missing or not executable"

max_line_chars="$(sed -n 's/^readonly max_line_chars="\${SP_BOOT_ATTEMPT_MAX_LINE_CHARS:-\([0-9]*\)}".*/\1/p' "$runner")"
[[ "$max_line_chars" =~ ^[0-9]+$ ]] || fail "could not read the runner's default console line cap"
# The cap is a bound on console volume, not a security control - key material is
# caught by shape. A default-pino JSON object with a child context runs ~140
# characters before the message, putting real error lines at 230-245, so a cap
# near that length silently drops exactly the lines that diagnose the node.
(( max_line_chars > 300 )) \
    || fail "line cap ${max_line_chars} is not clear of the 230-245 char log lines these services emit"

# Stands in for the boot-critical command. argv is logged so the test also
# proves the runner passes the unit's command line through unchanged.
cat >"$test_root/fake-cmd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$SP_TEST_ARGV_LOG"
case "$SP_TEST_BEHAVIOUR" in
    ok)
        echo "initialisation complete"
        exit 0
        ;;
    hang)
        echo "downloading release asset"
        sleep 300
        ;;
    slow-reject)
        # Alternates 0s/1s so the rendered reason ("...after Ns") differs
        # between consecutive attempts while the failure KIND does not. That is
        # the shape a real failure has - retries and backoff move the elapsed
        # seconds with network jitter - and a throttle keyed on the rendered
        # string prints its full block every single attempt.
        count=$(( $(cat "$SP_TEST_SLOW_COUNTER" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$count" >"$SP_TEST_SLOW_COUNTER"
        (( count % 2 == 0 )) && sleep 1
        echo "resolving api.github.com" >&2
        echo "ERROR: failed to fetch release info for Super-Protocol/swarm-db@v1.2.3" >&2
        exit 3
        ;;
    pino)
        # One default-pino JSON object per line with a child context, which is
        # what puts these error lines at 230-245 characters.
        echo '{"level":30,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"Trying sync server"}'
        echo '{"level":50,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"Failed attempt 3/3 for sync server: unable to verify the first certificate. Reason: tls-verification-failed"}' >&2
        echo '{"level":50,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"Error is not retryable for sync server; moving to next server. Reason: tls-verification-failed"}' >&2
        echo '{"level":50,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"caBundle fingerprint 329abfac433bc14636fe85052f8ba542132a77eb82d34a5c96de0f0676198706 does not match"}' >&2
        exit 1
        ;;
    pem)
        # A private key as it really arrives from pki-cert-generator at
        # --log-level debug: a BEGIN/END block whose body lines are nothing but
        # base64, and whose LAST body line is short enough not to be a token at
        # all - no per-line rule can reach that one.
        echo '{"level":50,"msg":"caBundle fingerprint 6624582b433bc14636fe85052f8ba542132a77eb82d34a5c96de0f0676198706 does not match"}' >&2
        echo 'swarm key was aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZA== and failed' >&2
        # Mentions a marker inside a message: must be dropped on its own without
        # opening a block and swallowing everything after it.
        echo '{"level":50,"msg":"unable to parse -----BEGIN CERTIFICATE----- block"}' >&2
        # Sits between the quoted marker and the real block's END, so it is
        # exactly what a substring delimiter match would swallow.
        echo 'diagnosis after a quoted marker: tls-verification-failed' >&2
        echo '-----BEGIN PRIVATE KEY-----' >&2
        echo 'KEYAAAAAb3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZGhlbGxvd29y' >&2
        echo 'KEYBBBBBb3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZGhlbGxvd29y' >&2
        echo 'KEYCCCCCb3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZGhlbGxvd29y' >&2
        echo 'KEYZZZZZshorttail==' >&2
        echo '-----END PRIVATE KEY-----' >&2
        echo 'trailing diagnosis: not retryable; moving to next server' >&2
        exit 1
        ;;
    pem-exotic-label)
        # RFC 7468 allows "-" inside a PEM label. A label the delimiter matcher
        # rejects does not merely go unlabelled: the block never opens, the body
        # falls through to the per-line rules, and the short final body line is
        # below token_min_chars and prints in full.
        echo '-----BEGIN FOO-BAR PRIVATE KEY-----' >&2
        echo 'KEYAAAAAb3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZGhlbGxvd29y' >&2
        echo 'KEYZZZZZshorttail==' >&2
        echo '-----END FOO-BAR PRIVATE KEY-----' >&2
        echo 'trailing diagnosis: not retryable; moving to next server' >&2
        exit 1
        ;;
    github-token)
        # The shapes the generic [A-Za-z0-9+/=]{40,} rule cannot see, because
        # "_" breaks the run: a classic PAT (ghp_ + 36 characters, so the run
        # after the underscore is 36 - under the threshold) and a fine-grained
        # one, split into three sub-threshold pieces by its own underscores.
        # swarm-init is the unit that carries github.token.
        echo "ERROR: failed to fetch release info for Super-Protocol/swarm-db@v1.2.3" >&2
        echo "ERROR: bad credentials for token ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8" >&2
        echo "ERROR: also github_pat_11ABCDEFG0aBcDeFgHiJkL_mNoPqRsTuVwXyZ0123456789abcdefghij failed" >&2
        # Must survive: an ordinary path with an underscore is not a token, and
        # neither is a short gh_-ish word.
        echo "ERROR: wrote /etc/swarm/swarm_node_env and ghs_ok" >&2
        exit 3
        ;;
    leak)
        # Shapes that must be caught line by line, outside any PEM block, with
        # the ordinary error kept. The unterminated BEGIN comes last on purpose:
        # a block with no END inside the window must suppress everything after
        # it, so it cannot sit above lines the test expects to survive.
        echo "contacting the authority"
        echo "token: MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDexampleexample" >&2
        echo "x: $(printf 'A%.0s' $(seq 1 300))" >&2
        echo "ERROR: chain generation refused: unknown CA" >&2
        echo "-----BEGIN PRIVATE KEY-----" >&2
        echo "LEAKEDBODYb3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZGhlbGxv" >&2
        exit 3
        ;;
    *)
        echo "starting"
        echo "ERROR: chain generation refused: unknown CA" >&2
        exit 3
        ;;
esac
EOF
chmod +x "$test_root/fake-cmd"

make_case() {
    local case_dir="$1"
    mkdir -p "$case_dir/state"
    : >"$case_dir/console"
}

run_attempt() {
    local case_dir="$1" behaviour="$2" attempt_timeout="${3:-60}"
    SP_BOOT_ATTEMPT_STATE_DIR="$case_dir/state" \
    SP_BOOT_ATTEMPT_CONSOLE="$case_dir/console" \
    SP_BOOT_ATTEMPT_CONSOLE_FULL_ATTEMPTS="${SP_TEST_CONSOLE_FULL_ATTEMPTS:-3}" \
    SP_BOOT_ATTEMPT_CONSOLE_FULL_EVERY="${SP_TEST_CONSOLE_FULL_EVERY:-60}" \
    SP_BOOT_ATTEMPT_MAX_LINE_CHARS="${SP_TEST_MAX_LINE_CHARS:-$max_line_chars}" \
    SP_BOOT_ATTEMPT_ERROR_TAIL_LINES="${SP_TEST_ERROR_TAIL_LINES:-20}" \
    SP_TEST_BEHAVIOUR="$behaviour" \
    SP_TEST_ARGV_LOG="$case_dir/argv.log" \
    SP_TEST_SLOW_COUNTER="$case_dir/slow-counter" \
        "$runner" \
            --unit demo-gate.service \
            --timeout "$attempt_timeout" \
            --action "the demo attempt" \
            --impact "Nothing behind this unit can start." \
            --detail "config:    /sp/swarm/config.yaml" \
            -- "$test_root/fake-cmd" --flag "a value" \
        >"$case_dir/stdout" 2>"$case_dir/stderr"
}

state_of() { printf '%s/state/demo-gate.json' "$1"; }

# --- the runner refuses to run without a bound ---

usage_console="$test_root/usage-console"
: >"$usage_console"
usage_rejects() {
    SP_BOOT_ATTEMPT_CONSOLE="$usage_console" "$runner" "$@" >/dev/null 2>&1 \
        && fail "the runner accepted: $*"
    return 0
}
usage_rejects --unit demo-gate.service -- /bin/true
usage_rejects --unit demo-gate.service --timeout infinity -- /bin/true
usage_rejects --unit demo-gate.service --timeout 10
usage_rejects --timeout 10 -- /bin/true
# Restart=on-failure would retry a malformed ExecStart forever, and a -release
# guest has no stderr an operator can read: the complaint has to reach the
# console or the node fails silently on a packaging mistake.
[[ "$(grep -c 'sp-boot-attempt. ERROR' "$usage_console")" == "4" ]] \
    || fail "a usage error did not reach the console: $(cat "$usage_console")"
grep -q 'demo-gate.service' "$usage_console" \
    || fail "the console does not say which unit was misconfigured"

# --- a healthy attempt ---

ok_dir="$test_root/ok"
make_case "$ok_dir"
run_attempt "$ok_dir" ok || fail "a successful attempt did not exit 0"
grep -q '"state": "ok"' "$(state_of "$ok_dir")" || fail "a successful attempt did not publish state ok"
grep -q '"unit": "demo-gate.service"' "$(state_of "$ok_dir")" || fail "the health state does not name the unit"
! grep -q FAILED "$ok_dir/console" || fail "a successful attempt wrote a failure banner to the console"
grep -q -- '--flag a value' "$ok_dir/argv.log" || fail "the command lost its arguments"

# --- a failing attempt is diagnosable from the console alone ---

bad_dir="$test_root/rejected"
make_case "$bad_dir"
run_attempt "$bad_dir" reject && fail "a failing attempt exited 0"
state_json="$(state_of "$bad_dir")"
grep -q '"state": "failed"' "$state_json" || fail "a failing attempt did not publish state failed"
grep -q '"exit_code": 3' "$state_json" || fail "the command's exit code is missing from the health state"
grep -q '"attempt": 1' "$state_json" || fail "the attempt number is missing from the health state"
grep -q '"reason_class": "exit-3"' "$state_json" || fail "the health state lost the stable reason class"
grep -q '"details": \["config:    /sp/swarm/config.yaml"\],' "$state_json" \
    || fail "the --detail lines did not reach the health state: $(cat "$state_json")"
grep -q 'demo-gate.service FAILED' "$bad_dir/console" || fail "the failure never reached the console"
grep -q 'Nothing behind this unit can start' "$bad_dir/console" \
    || fail "the console does not say what stays down"
grep -q 'config:    /sp/swarm/config.yaml' "$bad_dir/console" \
    || fail "the console lost the --detail lines"
grep -q 'chain generation refused: unknown CA' "$bad_dir/console" \
    || fail "the console does not carry the attempt's own error"

# --- the SUP-370 failure mode itself: something that answers but never finishes ---

hang_dir="$test_root/hang"
make_case "$hang_dir"
started="$SECONDS"
run_attempt "$hang_dir" hang 1 && fail "a hanging attempt exited 0"
elapsed=$((SECONDS - started))
(( elapsed < 60 )) || fail "a hanging attempt took ${elapsed}s to give up"
grep -q 'the demo attempt did not finish within 1s' "$(state_of "$hang_dir")" \
    || fail "a hanging attempt was not reported as a timeout: $(cat "$(state_of "$hang_dir")")"
grep -q '"reason_class": "timeout"' "$(state_of "$hang_dir")" \
    || fail "a hanging attempt was not classed as a timeout"
grep -q 'did not finish within 1s' "$hang_dir/console" \
    || fail "a hanging attempt did not report the timeout to the console"

# systemd restarts the unit; the health state has to show which attempt this is.
run_attempt "$bad_dir" reject && fail "the second failing attempt exited 0"
grep -q '"attempt": 2' "$state_json" || fail "the attempt counter does not advance across restarts"

# An image that lost the binary must say so rather than retry a missing file.
# Run in a state dir that already holds a previous attempt's output: the paths
# that report WITHOUT running the command (missing-command, and a signal that
# arrives before the pipeline) must not print that output under this attempt's
# "last N line(s) of the attempt" heading. On a -release guest the block is the
# whole diagnosis, so a stale tail is worse than no tail.
missing_dir="$test_root/missing-command"
make_case "$missing_dir"
run_attempt "$missing_dir" reject && fail "the seeding attempt exited 0"
grep -q 'chain generation refused' "$missing_dir/console" \
    || fail "the seeding attempt left no output to go stale"
: >"$missing_dir/console"
SP_BOOT_ATTEMPT_STATE_DIR="$missing_dir/state" SP_BOOT_ATTEMPT_CONSOLE="$missing_dir/console" \
    "$runner" --unit demo-gate.service --timeout 10 --action "the demo attempt" \
        -- /usr/local/bin/definitely-not-installed >/dev/null 2>&1 \
    && fail "a missing command exited 0"
grep -q 'is missing from this image' "$missing_dir/console" \
    || fail "a missing command was not reported to the console"
grep -q '"reason_class": "missing-command"' "$(state_of "$missing_dir")" \
    || fail "a missing command was not classed as such"
! grep -q 'chain generation refused' "$missing_dir/console" \
    || fail "the console showed the PREVIOUS attempt's output under this attempt's heading"
! grep -q 'line(s) of the attempt' "$missing_dir/console" \
    || fail "a tail heading was printed for an attempt whose command never ran"
# The invariant the above rests on, asserted directly - it is also what keeps
# the signal path (TimeoutStartSec kills the cgroup before the pipeline starts)
# from reporting somebody else's output.
[[ ! -s "$missing_dir/state/demo-gate.log" ]] \
    || fail "the attempt log still holds the previous attempt's output: $(cat "$missing_dir/state/demo-gate.log")"

# --- console discipline: an outage must not evict the original boot output ---

rate_dir="$test_root/rate-limit"
make_case "$rate_dir"
for expected_attempt in 1 2 3; do
    run_attempt "$rate_dir" reject && fail "failing attempt $expected_attempt exited 0"
    [[ "$(grep -c 'FAILED (attempt' "$rate_dir/console")" == "$expected_attempt" ]] \
        || fail "attempt $expected_attempt did not print its full console block"
done
# Fourth attempt, same reason: one line, no block.
run_attempt "$rate_dir" reject && fail "the fourth failing attempt exited 0"
[[ "$(grep -c 'FAILED (attempt' "$rate_dir/console")" == "3" ]] \
    || fail "the console block repeated once the reason had stopped changing"
grep -q 'still failing (attempt 4)' "$rate_dir/console" \
    || fail "a throttled attempt left no trace on the console at all"
# A different reason is new information and must print in full even when throttled.
run_attempt "$rate_dir" hang 1 && fail "the hanging attempt exited 0"
grep -q 'FAILED (attempt 5)' "$rate_dir/console" \
    || fail "a changed reason did not break through the console throttle"
# Hourly heartbeat: the block returns on a multiple of console_full_every.
printf '%s\n' 5 >"$rate_dir/state/demo-gate.attempt"
SP_TEST_CONSOLE_FULL_EVERY=6 run_attempt "$rate_dir" hang 1 && fail "the periodic attempt exited 0"
grep -q 'FAILED (attempt 6)' "$rate_dir/console" \
    || fail "the full block never returns on the periodic schedule"
# A success clears the remembered reason, so the same failure prints in full again.
run_attempt "$rate_dir" ok || fail "the recovering attempt did not exit 0"
printf '%s\n' 20 >"$rate_dir/state/demo-gate.attempt"
run_attempt "$rate_dir" hang 1 && fail "the post-recovery attempt exited 0"
grep -q 'FAILED (attempt 21)' "$rate_dir/console" \
    || fail "a failure after a success was throttled as a repeat"

# The throttle must key on the failure KIND, not on the rendered reason. The
# reject/hang fixtures above hold the duration still (they return instantly, so
# "after 0s" never moves), which is exactly how a string-keyed throttle passes
# while never engaging on a real node.
vary_dir="$test_root/varying-duration"
make_case "$vary_dir"
for i in $(seq 1 8); do
    run_attempt "$vary_dir" slow-reject && fail "varying-duration attempt $i exited 0"
done
full_blocks="$(grep -c 'FAILED (attempt' "$vary_dir/console")"
[[ "$full_blocks" == "3" ]] \
    || fail "a failure whose duration varies printed $full_blocks full blocks, expected 3"
[[ "$(grep -c 'still failing' "$vary_dir/console")" == "5" ]] \
    || fail "the throttled attempts did not each leave their one-liner"
# The per-attempt detail must survive where precision is wanted, just not in the key.
grep -qE '"reason": "the demo attempt exited with code 3 after [0-9]+s"' "$(state_of "$vary_dir")" \
    || fail "the health state lost the per-attempt elapsed seconds"
[[ "$(cat "$vary_dir/state/demo-gate.last-reason")" == "exit-3" ]] \
    || fail "the throttle key is not the reason class"

# --- key material must not reach the console ---

pino_dir="$test_root/pino"
make_case "$pino_dir"
run_attempt "$pino_dir" pino && fail "the pino-shaped attempt exited 0"
grep -q 'unable to verify the first certificate' "$pino_dir/console" \
    || fail "the line cap dropped the error that explains the failure"
grep -q 'moving to next server' "$pino_dir/console" \
    || fail "the line cap dropped the retry verdict"
# A fingerprint is key-SHAPED but is the SUP-370 root cause: redact the token,
# keep enough head to compare it against the authority's, keep the prose.
! grep -q '329abfac433bc14636fe85052f8ba542132a77eb82d34a5c96de0f0676198706' "$pino_dir/console" \
    || fail "a 64-char token reached the console whole"
grep -q '329abfac\.\.\. 64-char token redacted' "$pino_dir/console" \
    || fail "the redacted token kept no comparable head"
grep -q 'does not match' "$pino_dir/console" \
    || fail "redacting the token also threw away the message around it"

# A per-token head is safe for a digest and catastrophic for a key: a PEM body
# line is nothing but a token, so 8 characters from each of 25 of them is 200
# uniformly-sampled characters of the key. The block has to go as a block.
pem_dir="$test_root/pem"
make_case "$pem_dir"
run_attempt "$pem_dir" pem && fail "the key-leaking attempt exited 0"
for head in KEYAAAAA KEYBBBBB KEYCCCCC; do
    ! grep -q "$head" "$pem_dir/console" \
        || fail "a PEM body line gave up its first characters as a token head ($head)"
done
! grep -q 'KEYZZZZZshorttail==' "$pem_dir/console" \
    || fail "the short final PEM body line reached the console in full"
! grep -q -- '-----END' "$pem_dir/console" || fail "the PEM END delimiter reached the console"
[[ "$(grep -c '<suppressed: PEM block>' "$pem_dir/console")" == "1" ]] \
    || fail "the PEM block was not announced exactly once"
grep -q '6624582b\.\.\. 64-char token redacted' "$pem_dir/console" \
    || fail "a hex fingerprint lost its comparable head"
! grep -q 'aGVsbG93' "$pem_dir/console" || fail "a base64 token gave up a head"
grep -q '<56-char token redacted>' "$pem_dir/console" \
    || fail "a base64 token was not suppressed without a head"
grep -q 'moving to next server' "$pem_dir/console" \
    || fail "a quoted PEM marker swallowed the diagnosis that followed the block"
grep -q 'diagnosis after a quoted marker' "$pem_dir/console" \
    || fail "a quoted PEM marker opened a block and swallowed the line after it"

# A hyphenated label is still a PEM block.
exotic_dir="$test_root/pem-exotic-label"
make_case "$exotic_dir"
run_attempt "$exotic_dir" pem-exotic-label && fail "the exotic-label attempt exited 0"
! grep -q 'KEYZZZZZshorttail==' "$exotic_dir/console" \
    || fail "a hyphenated PEM label left the block unopened and leaked the short tail line"
! grep -q 'KEYAAAAA' "$exotic_dir/console" || fail "a hyphenated PEM label leaked a body line head"
[[ "$(grep -c '<suppressed: PEM block>' "$exotic_dir/console")" == "1" ]] \
    || fail "a hyphenated PEM label was not announced as a block"
grep -q 'moving to next server' "$exotic_dir/console" \
    || fail "the line after a hyphenated-label block was lost"

# The tail window can open inside a block whose BEGIN has already scrolled out.
midblock_dir="$test_root/pem-midblock"
make_case "$midblock_dir"
SP_TEST_ERROR_TAIL_LINES=5 run_attempt "$midblock_dir" pem && fail "the mid-block attempt exited 0"
for head in KEYBBBBB KEYCCCCC; do
    ! grep -q "$head" "$midblock_dir/console" \
        || fail "a window opening inside a PEM block leaked body line $head"
done
! grep -q 'KEYZZZZZshorttail==' "$midblock_dir/console" \
    || fail "a window opening inside a PEM block leaked the short tail line"
! grep -q -- '-----END' "$midblock_dir/console" \
    || fail "a window opening inside a PEM block leaked the END delimiter"
grep -q 'moving to next server' "$midblock_dir/console" \
    || fail "the line after the block was lost when the window opened mid-block"

leak_dir="$test_root/leak"
make_case "$leak_dir"
run_attempt "$leak_dir" leak && fail "the leaking attempt exited 0"
! grep -q 'BEGIN PRIVATE KEY' "$leak_dir/console" || fail "a PEM marker reached the console"
! grep -q 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDexampleexample' "$leak_dir/console" \
    || fail "a base64 run reached the console"
! grep -qE 'A{250}' "$leak_dir/console" || fail "a long run of identical characters reached the console"
# The shape detector, not the line cap, is what makes this safe: the same
# assertions must hold with the cap raised far out of the way.
SP_TEST_MAX_LINE_CHARS=100000 run_attempt "$leak_dir" leak \
    && fail "the leaking attempt exited 0 with the cap raised"
! grep -q 'BEGIN PRIVATE KEY' "$leak_dir/console" \
    || fail "the line cap, not the shape detector, was holding back the PEM marker"
! grep -q 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDexampleexample' "$leak_dir/console" \
    || fail "the line cap, not the shape detector, was holding back the base64 run"
! grep -qE 'A{250}' "$leak_dir/console" \
    || fail "the line cap, not the shape detector, was holding back the long run"
grep -q 'suppressed' "$leak_dir/console" || fail "suppressed lines left no marker, so the gap is invisible"
grep -q 'chain generation refused: unknown CA' "$leak_dir/console" \
    || fail "the redaction swallowed the ordinary error message too"
# A BEGIN with no END inside the window: everything after it is presumed body.
! grep -q 'LEAKEDBODY' "$leak_dir/console" || fail "an unterminated PEM block leaked its body"

# A GitHub token is the one credential swarm-init actually handles, and the
# generic token rule cannot see either of its shapes.
pat_dir="$test_root/github-token"
make_case "$pat_dir"
run_attempt "$pat_dir" github-token && fail "the token-leaking attempt exited 0"
! grep -q 'ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8' "$pat_dir/console" \
    || fail "a classic GitHub PAT reached the console verbatim"
! grep -q 'github_pat_11ABCDEFG0aBcDeFgHiJkL' "$pat_dir/console" \
    || fail "a fine-grained GitHub PAT reached the console verbatim"
! grep -q 'mNoPqRsTuVwXyZ0123456789abcdefghij' "$pat_dir/console" \
    || fail "the second half of a fine-grained PAT reached the console"
# The prefix is kept: it is not secret, and it says which kind of credential
# leaked - which is the whole diagnostic value the body never had.
grep -q '<ghp_ github token redacted>' "$pat_dir/console" \
    || fail "the classic PAT was not replaced by a labelled marker: $(cat "$pat_dir/console")"
grep -q '<github_pat_ github token redacted>' "$pat_dir/console" \
    || fail "the fine-grained PAT was not replaced by a labelled marker"
grep -q 'bad credentials for token' "$pat_dir/console" \
    || fail "redacting the token threw away the message around it"
grep -q 'failed to fetch release info' "$pat_dir/console" \
    || fail "the error that explains the failure was lost"
# Over-redaction is a real cost here: a prefix rule that eats ordinary words
# makes the console useless.
grep -q '/etc/swarm/swarm_node_env' "$pat_dir/console" \
    || fail "an ordinary underscored path was redacted as a token"
grep -q 'ghs_ok' "$pat_dir/console" \
    || fail "a short gh-prefixed word was redacted as a token"

echo "sp-boot-attempt tests passed"
