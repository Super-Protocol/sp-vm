#!/usr/bin/env bash

# SUP-372: pki-authority-sync must never become a boot gate again. Everything
# here is a regression guard for one of the three defects of the old unit - an
# unbounded TimeoutStartSec, a retry loop inside ExecStart, and a failure that
# left no trace a -release guest could show.
#
# SUP-376 adds the other half: the trace is now a published record that leaves
# the guest on an unauthenticated port, so this suite also pins the
# `sp.unit-health/v1` format, the terminal classification of the secrets 403,
# and the rule the endpoint's whole single-redactor argument rests on - that
# `reason` is composed by this publisher and never captured from the client.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_PKI_SYNC_TEST_INSTALLED_ROOT:-}" ]]; then
    config_dir="$SP_PKI_SYNC_TEST_INSTALLED_ROOT"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/etc/systemd/system"
else
    config_dir="$repository_root/src/rootfs/files/configs"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/pki-service/systemd"
fi
unit="$unit_dir/pki-authority-sync.service"
sync_script="$bin_dir/pki-authority-sync.sh"

# Shared with the tee-pki endpoint's redaction tripwire, byte for byte. See
# fixtures/sp-health-redaction/README.md: a real openssl genpkey key and a real
# captured pki-sync-client log, because both SUP-372 redaction bugs were
# invisible to a hand-written line.
fixtures_dir="${SP_PKI_SYNC_TEST_FIXTURES:-$script_dir/fixtures/sp-health-redaction}"
# Two captures and two keys, one pair from each repo, the UNION rather than a
# pick: each carries a leak shape the other lacks, and both suites assert
# against both. See fixtures/sp-health-redaction/README.md.
real_key="$fixtures_dir/private-key.pem"
real_403_log="$fixtures_dir/pki-sync-client-403.jsonl"
peer_key="$fixtures_dir/openssl-genpkey-rsa2048.pem"
peer_log="$fixtures_dir/pki-sync-client-pino.jsonl"
real_keys=("$real_key" "$peer_key")

test_root="$(mktemp -d -t sp-pki-authority-sync.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

unit_value() {
    sed -n "s/^$1=//p" "$unit" | tail -n1
}

json_field() {
    sed -n "s/^[[:space:]]*\"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$1" | tail -n1
}

# The one property both repositories assert on the same two artefacts: nothing
# matching the token pattern and no PEM marker reaches the surface.
assert_no_key_material() {
    local file="$1" what="$2" body key
    ! grep -q -- '-----BEGIN' "$file" || fail "$what: a PEM BEGIN marker reached it"
    ! grep -q -- '-----END' "$file" || fail "$what: a PEM END marker reached it"
    ! grep -qE '[A-Za-z0-9+/=]{40,}' "$file" \
        || fail "$what: a 40+ char base64/hex run reached it"
    # Hex with a separator every two characters has no 40-char run in it at
    # all, which is the shape the tee-pki capture exposed.
    ! grep -qE '([0-9A-Fa-f]{2}[: ]){19,}[0-9A-Fa-f]{2}' "$file" \
        || fail "$what: a 20+ pair delimited hex run reached it"
    for key in "${real_keys[@]}"; do
        while IFS= read -r body; do
            [[ -n "$body" ]] || continue
            case "$body" in -----*) continue ;; esac
            ! grep -qF "$body" "$file" \
                || fail "$what: a PEM body line of $(basename "$key") reached it whole"
            # SUP-372's second bug: an 8-character head per redacted token is
            # 200 uniformly-sampled characters of a 26-line key.
            ! grep -qF "${body:0:8}" "$file" \
                || fail "$what: a PEM body line of $(basename "$key") gave up its first 8 characters"
        done <"$key"
    done
}

# --- the unit must fail on its own instead of holding the boot transaction ---

[[ -f "$unit" ]] || fail "pki-authority-sync.service is missing from $unit_dir"

start_timeout="$(unit_value TimeoutStartSec)"
[[ "$start_timeout" =~ ^[0-9]+$ ]] \
    || fail "TimeoutStartSec must be a bounded number of seconds, got '${start_timeout:-<unset>}'"
(( start_timeout > 0 && start_timeout <= 900 )) \
    || fail "TimeoutStartSec=${start_timeout} is not the bounded few minutes SUP-372 asks for"

[[ "$(unit_value Restart)" == "on-failure" ]] \
    || fail "the retry must belong to systemd (Restart=on-failure), not to ExecStart"
restart_sec="$(unit_value RestartSec)"
[[ "$restart_sec" =~ ^[0-9]+$ ]] && (( restart_sec >= 10 )) \
    || fail "RestartSec must back the retry off, got '${restart_sec:-<unset>}'"
[[ "$(unit_value StartLimitIntervalSec)" == "0" ]] \
    || fail "StartLimitIntervalSec=0 is required, or systemd gives up on the unit entirely"

exec_start="$(unit_value ExecStart)"
[[ "$exec_start" == "/usr/local/bin/pki-authority-sync.sh" ]] \
    || fail "ExecStart must be the single-attempt script, got '$exec_start'"
! grep -qE '^(ExecStart|ExecStartPre)=.*(until |sleep )' "$unit" \
    || fail "a retry loop is back inside the unit's start commands"
! grep -q '^TimeoutStartSec=infinity' "$unit" \
    || fail "TimeoutStartSec=infinity is back"

# The three units whose start jobs die with JOB_DEPENDENCY when the boot-time
# attempt fails: nothing else would ever start them after a late success.
exec_start_post="$(grep '^ExecStartPost=' "$unit" || true)"
for dependent in swarm-db.service swarm-node.service swarm-services.service; do
    [[ "$exec_start_post" == *"$dependent"* ]] \
        || fail "a post-boot success does not revive $dependent"
done

[[ "$(grep -c '^WantedBy=multi-user.target$' "$unit")" == "1" ]] \
    || fail "the unit must still be installed into multi-user.target"

# --- the script's own bound must leave systemd room to hear the verdict ---

[[ -x "$sync_script" ]] || fail "pki-authority-sync.sh is missing or not executable"
attempt_timeout="$(sed -n 's/^readonly attempt_timeout="\${SP_PKI_SYNC_ATTEMPT_TIMEOUT:-\([0-9]*\)}".*/\1/p' "$sync_script")"
[[ "$attempt_timeout" =~ ^[0-9]+$ ]] \
    || fail "could not read the script's default attempt timeout"
(( attempt_timeout < start_timeout )) \
    || fail "attempt timeout ${attempt_timeout}s >= TimeoutStartSec ${start_timeout}s: systemd would kill the script before it reports"

# The console line cap is a bound on console volume, not a security control -
# key material is caught by shape. pki-sync-client logs one default-pino JSON
# object per line and its error lines measure 230-245 characters, so a cap near
# that length silently drops exactly the lines that diagnose the node.
max_line_chars="$(sed -n 's/^readonly max_line_chars="\${SP_PKI_SYNC_MAX_LINE_CHARS:-\([0-9]*\)}".*/\1/p' "$sync_script")"
[[ "$max_line_chars" =~ ^[0-9]+$ ]] || fail "could not read the script's default console line cap"
(( max_line_chars > 300 )) \
    || fail "line cap ${max_line_chars} is not clear of pki-sync-client's 230-245 char log lines"

if command -v systemd-analyze >/dev/null 2>&1; then
    verify_dir="$test_root/verify"
    mkdir -p "$verify_dir"
    cp "$unit" "$verify_dir/"
    verify_output="$(systemd-analyze verify --root=/ "$verify_dir/pki-authority-sync.service" 2>&1 || true)"
    # Unresolvable siblings and the absent script are expected off a real image;
    # a rejected directive is not.
    if grep -qiE 'refusing|not allowed|invalid|unknown (lvalue|section)' <<<"$verify_output"; then
        fail "systemd rejected the unit: $verify_output"
    fi
fi

# --- behaviour: every outcome terminates and leaves a readable verdict ---

make_env() {
    local case_dir="$1"
    mkdir -p "$case_dir/state" "$case_dir/certs"
    : >"$case_dir/console"
    # The hard shape for the script's awk parser: the authority list comes
    # before a literal CA block whose own lines start with "-", and a sibling
    # list of join addresses follows. Only the two authority servers may be
    # reported.
    cat >"$case_dir/swarm-env.yaml" <<'YAML'
pki_authority:
  servers:
  - 10.0.0.10:9443
  - '10.0.0.11:9443'
  caBundle: |
    -----BEGIN CERTIFICATE-----
    - not a server
    -----END CERTIFICATE-----
  secrets:
    swarmKey:
      saveTo: /etc/swarm/swarm.key
swarm_db:
  join_addresses:
  - 10.0.0.99:7946
YAML
    : >"$case_dir/client.js"
}

# Stands in for `node pki-sync-client`: argv[1] is the client path, the rest is
# the real command line, so the test also proves the script still passes it on.
cat >"$test_root/fake-node" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$SP_TEST_NODE_ARGV_LOG"
case "$SP_TEST_NODE_BEHAVIOUR" in
    ok)
        echo "sync completed"
        exit 0
        ;;
    hang)
        echo "connecting to authority"
        sleep 300
        ;;
    slow-reject)
        # Alternates 0s/1s so the rendered reason ("...after Ns") differs
        # between consecutive attempts while the failure KIND does not. This is
        # the shape the real client has - it tries each server with backoff, so
        # the elapsed seconds move with network jitter - and a throttle keyed on
        # the rendered string prints its full block every single attempt.
        count=$(( $(cat "$SP_TEST_SLOW_COUNTER" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$count" >"$SP_TEST_SLOW_COUNTER"
        (( count % 2 == 0 )) && sleep 1
        echo "connecting to authority"
        echo "authority rejected the CSR: unknown CA" >&2
        exit 3
        ;;
    pino)
        # The real pki-sync-client shape: default pino, one JSON object per
        # line, level/time/pid/hostname plus the {server, challengeType} child
        # context from sync-client.ts, which puts its error lines at 230-245
        # characters. Measured against pino's default field set.
        echo '{"level":30,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"Trying sync server"}'
        echo '{"level":50,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"Failed attempt 3/3 for sync server: unable to verify the first certificate. Reason: tls-verification-failed"}' >&2
        echo '{"level":50,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"Error is not retryable for sync server; moving to next server. Reason: tls-verification-failed"}' >&2
        echo '{"level":50,"time":1792418540082,"pid":1832211,"hostname":"swarm-node-2","server":"10.0.0.10:9443","challengeType":"sev-snp","msg":"caBundle fingerprint 329abfac433bc14636fe85052f8ba542132a77eb82d34a5c96de0f0676198706 does not match"}' >&2
        exit 1
        ;;
    pem)
        # A private key as it really arrives: a BEGIN/END block whose body lines
        # are nothing but base64, and whose LAST body line is short enough not
        # to be a token at all - no per-line rule can reach that one. Around it,
        # the shapes that must still survive or still be suppressed.
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
    secrets-403)
        # The real thing, replayed from the captured fixture: pino on stdout,
        # the CLI's own last word on stderr, exit 1 (cli.ts:33-34). This is the
        # SUP-370 shape - the authority issued a certificate with
        # validated=false and POST /api/v1/secrets/get then refused it.
        cat "$SP_TEST_REAL_403_LOG"
        echo 'Sync failed: Failed to sync from all servers' >&2
        exit 1
        ;;
    fixtures)
        # Both shared artefacts in one attempt, key FIRST so the whole of the
        # captured log is still inside the tail window after the block closes:
        # the diagnosis must survive, the key must not.
        cat "$SP_TEST_REAL_KEY" >&2
        cat "$SP_TEST_REAL_403_LOG"
        echo 'Sync failed: Failed to sync from all servers' >&2
        exit 1
        ;;
    http-4xx-*)
        # One behaviour, many codes: the terminal set is an explicit list, so
        # every member and every near-miss has to be exercised by code.
        code="${SP_TEST_NODE_BEHAVIOUR##http-4xx-}"
        echo "{\"level\":50,\"msg\":\"Failed attempt 1/1 for sync server: Request failed with status code ${code}. Reason: http-status:${code}\"}"
        echo "{\"level\":50,\"msg\":\"Error is not retryable for sync server; moving to next server. Reason: http-status:${code}\"}"
        exit 1
        ;;
    peer-capture)
        # The tee-pki half of the shared fixture: a real run of the real client
        # against a real authority, on the `untrusted` challenge. Its long
        # lines carry colon-separated SHA-256 fingerprints, which have no
        # 40-character run in them and so were invisible to the original shape
        # rule. It is also the NON-firing input - every diagnostic line in it
        # must survive, which is the half SUP-372's first regression broke.
        cat "$SP_TEST_PEER_LOG"
        echo 'Sync failed: Failed to sync from all servers' >&2
        exit 1
        ;;
    peer-fixtures)
        # The peer key through the same path, so neither repo's key is the only
        # one either redactor has ever seen.
        cat "$SP_TEST_PEER_KEY" >&2
        cat "$SP_TEST_PEER_LOG"
        exit 1
        ;;
    shapes)
        # Shapes that must SURVIVE: a MAC address, a 4-hex-group IPv6 address,
        # a host:port and a UUID are all diagnostic and all contain colons or
        # hex. The delimited-hex rule has to sit above them.
        echo 'link up on 52:54:00:12:34:56 after 3s' >&2
        echo 'peer address 2001:0db8:85a3:0000:0000:8a2e:0370:7334 unreachable' >&2
        echo 'authority 10.77.0.4:9443 refused; node id 550e8400-e29b-41d4-a716-446655440000' >&2
        # ...and two that must not: a colon fingerprint and an xxd-spaced run.
        echo 'fingerprint 17:F2:A7:7C:75:9D:F0:84:9D:4D:47:7D:58:A3:1A:07:48:E7:A2:57:26:84:CB:7F:6A:08:79:1B:8A:1E:44:CC does not match' >&2
        echo 'hexdump de ad be ef de ad be ef de ad be ef de ad be ef de ad be ef de ad be ef trailing' >&2
        exit 1
        ;;
    http-500)
        # 500 is not in RETRYABLE_HTTP_STATUS_CODES either, so the client logs
        # the same non-retryable verdict - but a server fault can be fixed
        # without touching this node, so it must NOT end anyone's wait.
        echo '{"level":50,"msg":"Error is not retryable for sync server; moving to next server. Reason: http-status:500"}'
        exit 1
        ;;
    http-429)
        # Defensive: 429 IS retryable today, so the client never pairs it with
        # this verdict. If that ever changes, the rate limit must not become a
        # terminal refusal.
        echo '{"level":50,"msg":"Error is not retryable for sync server; moving to next server. Reason: http-status:429"}'
        exit 1
        ;;
    network-code)
        # The parser must take the status from http-status: only. A network
        # code is the SUP-370 counter-example: it looks identical at this layer
        # and the next restart may well succeed.
        echo '{"level":50,"msg":"Error is not retryable for sync server; moving to next server. Reason: network-code:EHOSTUNREACH"}'
        exit 1
        ;;
    leak)
        # Shapes that must be caught line by line, outside any PEM block, with
        # the ordinary error kept. The unterminated BEGIN comes last on purpose:
        # a block with no END inside the window must suppress everything after
        # it, so it cannot sit above lines the test expects to survive.
        echo "connecting to authority"
        echo "token: MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDexampleexample" >&2
        echo "x: $(printf 'A%.0s' $(seq 1 300))" >&2
        echo "authority rejected the CSR: unknown CA" >&2
        echo "-----BEGIN PRIVATE KEY-----" >&2
        echo "LEAKEDBODYb3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG93b3JsZGhlbGxv" >&2
        exit 3
        ;;
    *)
        echo "connecting to authority"
        echo "authority rejected the CSR: unknown CA" >&2
        exit 3
        ;;
esac
EOF
chmod +x "$test_root/fake-node"

run_sync() {
    local case_dir="$1" behaviour="$2" attempt_timeout_override="${3:-240}"
    SP_PKI_SYNC_NODE="$test_root/fake-node" \
    SP_PKI_SYNC_CONSOLE_FULL_ATTEMPTS="${SP_TEST_CONSOLE_FULL_ATTEMPTS:-3}" \
    SP_PKI_SYNC_CONSOLE_FULL_EVERY="${SP_TEST_CONSOLE_FULL_EVERY:-60}" \
    SP_PKI_SYNC_CLIENT="$case_dir/client.js" \
    SP_PKI_SYNC_SECRETS_CONFIG="$case_dir/secrets.yaml" \
    SP_PKI_SYNC_SWARM_ENV="$case_dir/swarm-env.yaml" \
    SP_PKI_SYNC_CERTS_DIR="$case_dir/certs" \
    SP_PKI_SYNC_NETWORK_TYPE_FILE="$case_dir/network-type" \
    SP_PKI_SYNC_STATE_DIR="$case_dir/state" \
    SP_PKI_SYNC_CONSOLE="$case_dir/console" \
    SP_PKI_SYNC_ATTEMPT_TIMEOUT="$attempt_timeout_override" \
    SP_PKI_SYNC_MAX_LINE_CHARS="${SP_TEST_MAX_LINE_CHARS:-$max_line_chars}" \
    SP_PKI_SYNC_ERROR_TAIL_LINES="${SP_TEST_ERROR_TAIL_LINES:-20}" \
    SP_TEST_NODE_BEHAVIOUR="$behaviour" \
    SP_TEST_NODE_ARGV_LOG="$case_dir/argv.log" \
    SP_TEST_SLOW_COUNTER="$case_dir/slow-counter" \
    SP_TEST_REAL_KEY="$real_key" \
    SP_TEST_REAL_403_LOG="$real_403_log" \
    SP_TEST_PEER_KEY="$peer_key" \
    SP_TEST_PEER_LOG="$peer_log" \
        "$sync_script" >"$case_dir/stdout" 2>"$case_dir/stderr"
}

# A healthy sync reports ok and says nothing alarming on the console.
ok_dir="$test_root/ok"
make_env "$ok_dir"
run_sync "$ok_dir" ok || fail "a successful sync did not exit 0"
grep -q '"state": "ok"' "$ok_dir/state/pki-authority-sync.json" \
    || fail "a successful sync did not publish state ok"
! grep -q FAILED "$ok_dir/console" \
    || fail "a successful sync wrote a failure banner to the console"
grep -q -- '--save-certs-prefix vm' "$ok_dir/argv.log" \
    || fail "the sync client lost its command line"
grep -q -- "--swarm-env $ok_dir/swarm-env.yaml" "$ok_dir/argv.log" \
    || fail "the sync client was not pointed at the generated swarm env"

# A rejected sync fails the unit and is diagnosable from the console alone.
bad_dir="$test_root/rejected"
make_env "$bad_dir"
run_sync "$bad_dir" reject && fail "a rejected sync exited 0"
state_json="$bad_dir/state/pki-authority-sync.json"
grep -q '"state": "failed"' "$state_json" || fail "a rejected sync did not publish state failed"
grep -q '"exit_code": 3' "$state_json" || fail "the client's exit code is missing from the health state"
grep -q '"attempt": 1' "$state_json" || fail "the attempt number is missing from the health state"
grep -q '"authority_servers": \["10.0.0.10:9443", "10.0.0.11:9443"\],' "$state_json" \
    || fail "the health state does not name exactly the authority that refused: $(cat "$state_json")"
grep -q 'pki-authority-sync.service FAILED' "$bad_dir/console" \
    || fail "the failure never reached the console"
grep -q '10.0.0.10:9443' "$bad_dir/console" \
    || fail "the console does not name the authority that refused"
grep -q 'authority rejected the CSR: unknown CA' "$bad_dir/console" \
    || fail "the console does not carry the attempt's own error"

# The SUP-372 failure mode itself: an authority that answers but never signs.
# The attempt must end on its own, so systemd can fail the job and let boot
# finish instead of waiting forever.
hang_dir="$test_root/hang"
make_env "$hang_dir"
started="$SECONDS"
run_sync "$hang_dir" hang 1 && fail "a hanging sync exited 0"
elapsed=$((SECONDS - started))
(( elapsed < 60 )) || fail "a hanging sync took ${elapsed}s to give up"
grep -q 'did not complete the sync within 1s' "$hang_dir/state/pki-authority-sync.json" \
    || fail "a hanging sync was not reported as a timeout: $(cat "$hang_dir/state/pki-authority-sync.json")"
grep -q 'did not complete the sync within 1s' "$hang_dir/console" \
    || fail "a hanging sync did not report the timeout to the console"

# systemd restarts the unit; the health state has to show which attempt this is.
run_sync "$bad_dir" reject && fail "the second rejected sync exited 0"
grep -q '"attempt": 2' "$state_json" \
    || fail "the attempt counter does not advance across restarts"

# An image that lost the client must say so rather than retry a missing file.
missing_dir="$test_root/missing-client"
make_env "$missing_dir"
rm -f "$missing_dir/client.js"
run_sync "$missing_dir" ok && fail "a missing sync client exited 0"
grep -q 'is missing from this image' "$missing_dir/console" \
    || fail "a missing sync client was not reported to the console"

# The console is a bounded shared buffer: an outage of SUP-370's length must not
# push the original boot output out of the logs QA collects as forensics.
rate_dir="$test_root/rate-limit"
make_env "$rate_dir"
for expected_attempt in 1 2 3; do
    run_sync "$rate_dir" reject && fail "rejected sync $expected_attempt exited 0"
    [[ "$(grep -c 'FAILED (attempt' "$rate_dir/console")" == "$expected_attempt" ]] \
        || fail "attempt $expected_attempt did not print its full console block"
done
# Fourth attempt, same reason: one line, no block.
run_sync "$rate_dir" reject && fail "the fourth rejected sync exited 0"
[[ "$(grep -c 'FAILED (attempt' "$rate_dir/console")" == "3" ]] \
    || fail "the console block repeated once the reason had stopped changing"
grep -q 'still failing (attempt 4)' "$rate_dir/console" \
    || fail "a throttled attempt left no trace on the console at all"
# A different reason is new information and must print in full even when throttled.
run_sync "$rate_dir" hang 1 && fail "the hanging sync exited 0"
grep -q 'FAILED (attempt 5)' "$rate_dir/console" \
    || fail "a changed reason did not break through the console throttle"
# Hourly heartbeat: the block returns on a multiple of console_full_every.
printf '%s\n' 5 >"$rate_dir/state/pki-authority-sync.attempt"
SP_TEST_CONSOLE_FULL_EVERY=6 run_sync "$rate_dir" hang 1 && fail "the periodic sync exited 0"
grep -q 'FAILED (attempt 6)' "$rate_dir/console" \
    || fail "the full block never returns on the periodic schedule"
# A success clears the remembered reason, so the same failure prints in full again.
run_sync "$rate_dir" ok || fail "the recovering sync did not exit 0"
printf '%s\n' 20 >"$rate_dir/state/pki-authority-sync.attempt"
run_sync "$rate_dir" hang 1 && fail "the post-recovery sync exited 0"
grep -q 'FAILED (attempt 21)' "$rate_dir/console" \
    || fail "a failure after a success was throttled as a repeat"

# The throttle must key on the failure KIND, not on the rendered reason. The
# reject/hang fixtures above hold the duration still (they return instantly, so
# "after 0s" never moves), which is exactly how a string-keyed throttle passes
# while never engaging on a real node.
vary_dir="$test_root/varying-duration"
make_env "$vary_dir"
for i in $(seq 1 8); do
    run_sync "$vary_dir" slow-reject && fail "varying-duration sync $i exited 0"
done
full_blocks="$(grep -c 'FAILED (attempt' "$vary_dir/console")"
[[ "$full_blocks" == "3" ]] \
    || fail "a rejection whose duration varies printed $full_blocks full blocks, expected 3"
[[ "$(grep -c 'still failing' "$vary_dir/console")" == "5" ]] \
    || fail "the throttled attempts did not each leave their one-liner"
# The per-attempt detail must survive where precision is wanted, just not in the key.
grep -q '"reason_class": "exit-3"' "$vary_dir/state/pki-authority-sync.json" \
    || fail "the health state lost the stable reason class"
grep -qE '"reason": "pki-sync-client exited with code 3 after [0-9]+s"' \
    "$vary_dir/state/pki-authority-sync.json" \
    || fail "the health state lost the per-attempt elapsed seconds"
[[ "$(cat "$vary_dir/state/pki-authority-sync.last-reason")" == "exit-3" ]] \
    || fail "the throttle key is not the reason class"

# The real client's lines are 230-245 characters: a cap near that length drops
# precisely the lines that diagnose the node.
pino_dir="$test_root/pino"
make_env "$pino_dir"
run_sync "$pino_dir" pino && fail "the pino-shaped sync exited 0"
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
make_env "$pem_dir"
run_sync "$pem_dir" pem && fail "the key-leaking sync exited 0"
for head in KEYAAAAA KEYBBBBB KEYCCCCC; do
    ! grep -q "$head" "$pem_dir/console" \
        || fail "a PEM body line gave up its first characters as a token head ($head)"
done
! grep -q 'KEYZZZZZshorttail==' "$pem_dir/console" \
    || fail "the short final PEM body line reached the console in full"
! grep -q -- '-----END' "$pem_dir/console" \
    || fail "the PEM END delimiter reached the console"
[[ "$(grep -c '<suppressed: PEM block>' "$pem_dir/console")" == "1" ]] \
    || fail "the PEM block was not announced exactly once"
# Hex keeps a head - a fingerprint is the SUP-370 diagnosis. Base64 does not:
# the head of a secret was never diagnostic.
grep -q '6624582b\.\.\. 64-char token redacted' "$pem_dir/console" \
    || fail "a hex fingerprint lost its comparable head"
! grep -q 'aGVsbG93' "$pem_dir/console" \
    || fail "a base64 token gave up a head"
grep -q '<56-char token redacted>' "$pem_dir/console" \
    || fail "a base64 token was not suppressed without a head"
grep -q 'does not match' "$pem_dir/console" \
    || fail "redacting the fingerprint threw away the message around it"
# A marker quoted inside a log message must drop that line only - not open a
# block and swallow the rest of the tail.
grep -q 'moving to next server' "$pem_dir/console" \
    || fail "a quoted PEM marker swallowed the diagnosis that followed the block"
grep -q 'diagnosis after a quoted marker' "$pem_dir/console" \
    || fail "a quoted PEM marker opened a block and swallowed the line after it"

# A hyphenated label is still a PEM block.
exotic_dir="$test_root/pem-exotic-label"
make_env "$exotic_dir"
run_sync "$exotic_dir" pem-exotic-label && fail "the exotic-label sync exited 0"
! grep -q 'KEYZZZZZshorttail==' "$exotic_dir/console" \
    || fail "a hyphenated PEM label left the block unopened and leaked the short tail line"
! grep -q 'KEYAAAAA' "$exotic_dir/console" \
    || fail "a hyphenated PEM label leaked a body line head"
! grep -q -- '-----END' "$exotic_dir/console" \
    || fail "a hyphenated PEM label leaked the END delimiter"
[[ "$(grep -c '<suppressed: PEM block>' "$exotic_dir/console")" == "1" ]] \
    || fail "a hyphenated PEM label was not announced as a block"
grep -q 'moving to next server' "$exotic_dir/console" \
    || fail "the line after a hyphenated-label block was lost"

# The tail window can open inside a block whose BEGIN has already scrolled out.
midblock_dir="$test_root/pem-midblock"
make_env "$midblock_dir"
SP_TEST_ERROR_TAIL_LINES=5 run_sync "$midblock_dir" pem \
    && fail "the mid-block sync exited 0"
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

# /dev/console on a confidential VM is outside the TEE boundary, and the tail is
# another repository's debug output: nothing key-shaped may reach it.
leak_dir="$test_root/leak"
make_env "$leak_dir"
run_sync "$leak_dir" leak && fail "the leaking sync exited 0"
! grep -q 'BEGIN PRIVATE KEY' "$leak_dir/console" \
    || fail "a PEM marker reached the console"
! grep -q 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDexampleexample' "$leak_dir/console" \
    || fail "a base64 run reached the console"
! grep -qE 'A{250}' "$leak_dir/console" \
    || fail "a long run of identical characters reached the console"
# The shape detector, not the line cap, is what makes this safe: the same
# assertions must hold with the cap raised far out of the way.
SP_TEST_MAX_LINE_CHARS=100000 run_sync "$leak_dir" leak \
    && fail "the leaking sync exited 0 with the cap raised"
! grep -q 'BEGIN PRIVATE KEY' "$leak_dir/console" \
    || fail "the line cap, not the shape detector, was holding back the PEM marker"
! grep -q 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDexampleexample' "$leak_dir/console" \
    || fail "the line cap, not the shape detector, was holding back the base64 run"
! grep -qE 'A{250}' "$leak_dir/console" \
    || fail "the line cap, not the shape detector, was holding back the long run"
grep -q 'suppressed' "$leak_dir/console" \
    || fail "suppressed lines left no marker, so the gap is invisible"
grep -q 'authority rejected the CSR: unknown CA' "$leak_dir/console" \
    || fail "the redaction swallowed the ordinary error message too"
# A BEGIN with no END inside the window: everything after it is presumed body.
# Losing the rest of the tail is the right trade against leaking a key.
! grep -q 'LEAKEDBODY' "$leak_dir/console" \
    || fail "an unterminated PEM block leaked its body"

# ===========================================================================
# SUP-376: the record is now a published surface, not just a local breadcrumb
# ===========================================================================

# --- the sp.unit-health/v1 fields ------------------------------------------
# The three added fields each exist because a reader OUTSIDE the guest has to
# act on them, so each is pinned here rather than left to the endpoint.

schema_dir="$test_root/schema"
make_env "$schema_dir"
schema_json="$schema_dir/state/pki-authority-sync.json"

run_sync "$schema_dir" reject && fail "the schema-case sync exited 0"
[[ "$(json_field "$schema_json" schema)" == "sp.unit-health/v1" ]] \
    || fail "the record does not name its schema: $(cat "$schema_json")"
[[ "$(json_field "$schema_json" gate)" == "true" ]] \
    || fail "a unit without which the node cannot serve must publish gate: true"
# ttl_sec exists so that `attempting` left behind by a SIGKILLed publisher is
# read as stale rather than as "still booting" for 25 hours.
ttl_sec="$(json_field "$schema_json" ttl_sec)"
[[ "$ttl_sec" =~ ^[0-9]+$ ]] || fail "ttl_sec is not a number: '${ttl_sec:-<unset>}'"
(( ttl_sec > attempt_timeout )) \
    || fail "ttl_sec ${ttl_sec} is not clear of the ${attempt_timeout}s attempt it bounds: a live attempt would read as stale"
(( ttl_sec <= attempt_timeout * 4 )) \
    || fail "ttl_sec ${ttl_sec} is far longer than the attempt it bounds; a dead publisher stays 'fresh' for too long"

# A failure the next restart may clear is NOT terminal - that distinction is
# the whole point of the field.
[[ "$(json_field "$schema_json" terminal)" == "false" ]] \
    || fail "a plain non-zero exit was published as terminal"
[[ "$(json_field "$schema_json" state)" == "failed" ]] \
    || fail "the schema case did not fail"

# An in-flight attempt must never claim a wait can end either.
run_sync "$schema_dir" hang 1 && fail "the hanging schema sync exited 0"
[[ "$(json_field "$schema_json" terminal)" == "false" ]] \
    || fail "a timeout was published as terminal; an authority can come back"

# A missing client cannot be fixed by restarting: the image is signed.
missing_json="$missing_dir/state/pki-authority-sync.json"
[[ "$(json_field "$missing_json" terminal)" == "true" ]] \
    || fail "a client missing from a signed image was not published as terminal"
[[ "$(json_field "$missing_json" reason_class)" == "missing-client" ]] \
    || fail "the missing client lost its reason class"

# --- the secrets 403, from the real captured log ---------------------------
# Finding 2 of the contract: this fact is computed inside the guest today and
# destroyed one layer before it is published. Only the publisher can tell a 403
# from an ECONNREFUSED, so the endpoint cannot recover it.

for fixture in "$real_key" "$real_403_log" "$peer_key" "$peer_log"; do
    [[ -s "$fixture" ]] || fail "shared fixture $(basename "$fixture") is missing or empty"
done
# Guard the fixtures themselves: if either capture ever shrinks back below the
# cap that dropped every real line in SUP-372, this suite stops proving
# anything, silently.
for capture in "$real_403_log" "$peer_log"; do
    longest_fixture_line="$(awk '{ if (length > m) m = length } END { print m + 0 }' "$capture")"
    (( longest_fixture_line >= 230 )) \
        || fail "$(basename "$capture") longest line is ${longest_fixture_line} chars; the fixture no longer has the real shape"
done
# And guard what makes the UNION worth having rather than a pick: each capture
# must still carry the shape the other lacks. The tee-pki capture is the only
# source of delimited hex; ours is the only one that reaches the 403 classifier.
grep -qE '([0-9A-Fa-f]{2}:){19,}[0-9A-Fa-f]{2}' "$peer_log" \
    || fail "the tee-pki capture no longer carries a colon-separated fingerprint - the shape it exists to cover"
grep -q 'Reason: http-status:403' "$real_403_log" \
    || fail "the sp-vm capture no longer carries the 403 verdict it exists to cover"
for key in "${real_keys[@]}"; do
    [[ "$(grep -c . "$key")" -ge 20 ]] \
        || fail "$(basename "$key") is too short to be a real RSA key"
done

terminal_dir="$test_root/secrets-403"
make_env "$terminal_dir"
terminal_json="$terminal_dir/state/pki-authority-sync.json"
run_sync "$terminal_dir" secrets-403 && fail "the 403 sync exited 0"
[[ "$(json_field "$terminal_json" reason_class)" == "http-403-unvalidated" ]] \
    || fail "the secrets 403 was published as '$(json_field "$terminal_json" reason_class)', not http-403-unvalidated"
[[ "$(json_field "$terminal_json" terminal)" == "true" ]] \
    || fail "the secrets 403 was not published as terminal: no retry of it can ever succeed"
[[ "$(json_field "$terminal_json" state)" == "failed" ]] \
    || fail "the secrets 403 did not fail the unit"
# The console must end the operator's wait rather than extend it.
grep -q 'This failure is TERMINAL' "$terminal_dir/console" \
    || fail "a terminal failure still told the console that systemd would retry"
! grep -q 'boot is no longer blocked' "$terminal_dir/console" \
    || fail "a terminal failure printed the non-terminal reassurance"
# And the throttle key stays the stable class, not the rendered reason.
[[ "$(cat "$terminal_dir/state/pki-authority-sync.last-reason")" == "http-403-unvalidated" ]] \
    || fail "the terminal class is not the throttle key"

# Everything that is NOT a refusal of this node must stay non-terminal: a
# terminal verdict told to stop a wait is only useful if it is never wrong.
for case_name in http-500 http-429 network-code; do
    nonterm_dir="$test_root/nonterminal-$case_name"
    make_env "$nonterm_dir"
    run_sync "$nonterm_dir" "$case_name" && fail "the $case_name sync exited 0"
    nonterm_json="$nonterm_dir/state/pki-authority-sync.json"
    [[ "$(json_field "$nonterm_json" terminal)" == "false" ]] \
        || fail "$case_name was published as terminal, which would stop a wait that should continue"
    [[ "$(json_field "$nonterm_json" reason_class)" == "exit-1" ]] \
        || fail "$case_name was classified as '$(json_field "$nonterm_json" reason_class)'"
done

# The terminal 4xx set is an explicit list, not a range, so every member and
# every near-miss is exercised by code rather than by the comment next to it.
#
# In: a refusal of THIS NODE - a malformed, unauthenticated or unvalidated
# client certificate is a property the node carries to every authority in the
# list, so trying the next one cannot help.
for code in 400 401 403 422; do
    term_dir="$test_root/terminal-$code"
    make_env "$term_dir"
    run_sync "$term_dir" "http-4xx-$code" && fail "the $code sync exited 0"
    term_json="$term_dir/state/pki-authority-sync.json"
    [[ "$(json_field "$term_json" terminal)" == "true" ]] \
        || fail "HTTP $code was not published as terminal"
    if (( code == 403 )); then
        # 403 keeps its precedence and its own class: it is the SUP-370 shape,
        # a certificate the authority issued and then would not accept.
        [[ "$(json_field "$term_json" reason_class)" == "http-403-unvalidated" ]] \
            || fail "403 lost its specific class to the generic one"
    else
        [[ "$(json_field "$term_json" reason_class)" == "http-${code}-refused" ]] \
            || fail "HTTP $code lost its status code: $(json_field "$term_json" reason_class)"
    fi
done

# Out, and this is the correction that matters: a 404 from an authority that
# predates the route is a CLUSTER property, not a node property. Version skew
# is routine, and publishing terminal: true for it would tell an operator to
# replace a healthy node - the one mistake this field must never make. 405, 409
# and 410 are the same story, and 451 stands in for "a 4xx nobody has thought
# about yet", which must default to retryable.
for code in 404 405 409 410 451; do
    skew_dir="$test_root/nonterminal-$code"
    make_env "$skew_dir"
    run_sync "$skew_dir" "http-4xx-$code" && fail "the $code sync exited 0"
    skew_json="$skew_dir/state/pki-authority-sync.json"
    [[ "$(json_field "$skew_json" terminal)" == "false" ]] \
        || fail "HTTP $code was published as terminal: a cluster-side fault would be reported as a dead node"
    [[ "$(json_field "$skew_json" reason_class)" == "exit-1" ]] \
        || fail "HTTP $code was classified as '$(json_field "$skew_json" reason_class)'"
done

# --- reason is COMPOSED, never CAPTURED ------------------------------------
# This is the rule the endpoint's single-redactor argument rests on, so it is
# enforced here rather than left true by observation.

# Statically: the moment a call site interpolates a command substitution,
# captured third-party text is one `$(tail ...)` away from the record.
if grep -nE '^[[:space:]]*write_state ' "$sync_script" | grep -q '\$('; then
    fail "a write_state call interpolates a command substitution: $(grep -nE '^[[:space:]]*write_state ' "$sync_script" | grep '\$(')"
fi

# At runtime: every record this suite produced must carry a reason and a class
# from the publisher's own closed set, whatever the client printed.
reason_templates=(
    '^sync attempt [0-9]+ in progress$'
    '^synced with the authority on attempt [0-9]+ after [0-9]+s$'
    '^attempt [0-9]+ terminated by signal before it finished$'
    '^sync client [^ ]+ is missing from this image$'
    '^the authority did not complete the sync within [0-9]+s$'
    '^the authority issued a certificate it will not accept \(secrets 403\)$'
    '^the authority refused this node with HTTP [0-9]{3}$'
    '^pki-sync-client exited with code [0-9]+ after [0-9]+s$'
)
class_template='^(attempting|ok|signal|missing-client|timeout|exit-[0-9]+|http-403-unvalidated|http-[0-9]{3}-refused)$'

records=0
while IFS= read -r record; do
    records=$((records + 1))
    record_reason="$(json_field "$record" reason)"
    record_class="$(json_field "$record" reason_class)"
    [[ "$record_class" =~ $class_template ]] \
        || fail "$record: reason_class '$record_class' is outside the publisher's closed set"
    matched=0
    for template in "${reason_templates[@]}"; do
        [[ "$record_reason" =~ $template ]] && { matched=1; break; }
    done
    (( matched )) \
        || fail "$record: reason '$record_reason' is not one of the publisher's templates - something captured reached the record"
done < <(find "$test_root" -name pki-authority-sync.json)
(( records >= 10 )) || fail "only $records records were checked for composed reasons"

# --- the shared fixtures, end to end --------------------------------------
# A real key and a real captured log through the real script. The identical
# artefacts and the identical assertion live on the tee-pki side.

shared_dir="$test_root/shared-fixtures"
make_env "$shared_dir"
shared_json="$shared_dir/state/pki-authority-sync.json"
SP_TEST_ERROR_TAIL_LINES=60 run_sync "$shared_dir" fixtures \
    && fail "the shared-fixture sync exited 0"

assert_no_key_material "$shared_dir/console" "the console"
assert_no_key_material "$shared_json" "the published record"
# The record is the surface that leaves the guest: no third-party text at all.
! grep -q 'Request failed with status code' "$shared_json" \
    || fail "the client's own message reached the published record"
! grep -q 'swarm-node-2\|10.77.0' "$shared_json" \
    || fail "the client's log context reached the published record"
[[ "$(json_field "$shared_json" reason_class)" == "http-403-unvalidated" ]] \
    || fail "the shared fixture was not classified from the real captured log"
[[ "$(json_field "$shared_json" terminal)" == "true" ]] \
    || fail "the shared fixture was not published as terminal"

# ...and the captured text is exactly where SUP-372 put it: the console tail
# and the attempt log, which never leave the node.
grep -q 'Reason: http-status:403' "$shared_dir/console" \
    || fail "the redaction swallowed the one line that diagnoses the 403"
grep -q 'moving to next server' "$shared_dir/console" \
    || fail "the key block swallowed the diagnosis that followed it"
grep -q -- '-----BEGIN PRIVATE KEY-----' "$shared_dir/state/pki-authority-sync.log" \
    || fail "the attempt log lost the raw client output it exists to keep"
[[ "$(grep -c '<suppressed: PEM block>' "$shared_dir/console")" == "1" ]] \
    || fail "the real key block was not announced exactly once"

# --- the same assertions through the tee-pki half of the union -------------
# Two repos, two captures, two keys, the same property asserted on all of it.
# A pick rather than a union would leave each redactor pinned only by its own
# capture, which is how §4 reads as satisfied while nothing is actually shared.

peer_dir="$test_root/peer-fixtures"
make_env "$peer_dir"
SP_TEST_ERROR_TAIL_LINES=60 run_sync "$peer_dir" peer-fixtures \
    && fail "the peer-fixture sync exited 0"
assert_no_key_material "$peer_dir/console" "the console, on the peer key"
assert_no_key_material "$peer_dir/state/pki-authority-sync.json" "the published record, on the peer key"

# The peer capture is the NON-firing input: it is a successful run of the real
# client, and every diagnostic line in it has to survive. SUP-372's first
# regression was an over-broad rule that dropped exactly these.
peer_log_dir="$test_root/peer-capture"
make_env "$peer_log_dir"
SP_TEST_ERROR_TAIL_LINES=40 run_sync "$peer_log_dir" peer-capture \
    && fail "the peer-capture sync exited 0"
assert_no_key_material "$peer_log_dir/console" "the console, on the peer capture"
for survivor in \
    'Root certificate network type' \
    'connect ECONNREFUSED' \
    'Successfully synced from server' \
    'CN=SuperProtocol TEE Root CA'; do
    grep -qF "$survivor" "$peer_log_dir/console" \
        || fail "the redaction dropped a diagnostic line of the peer capture: '$survivor'"
done
# ...and the shape the union exposed: 32 colon-separated hex pairs have no
# 40-character run in them, so the original rule passed them through whole.
! grep -qF '17:F2:A7:7C:75:9D:F0:84' "$peer_log_dir/console" \
    || fail "a colon-separated fingerprint reached the console whole"
grep -qF '17:F2:A7... 95-char token redacted' "$peer_log_dir/console" \
    || fail "the delimited-hex token kept no comparable head"

# The delimited-hex rule has to sit ABOVE the shapes that are diagnostic and
# must survive it. A MAC address is 6 pairs and an IPv6 address is 4-hex
# groups, so neither can be mistaken for a 20-pair run.
shape_dir="$test_root/shapes"
make_env "$shape_dir"
run_sync "$shape_dir" shapes && fail "the shapes sync exited 0"
for survivor in \
    '52:54:00:12:34:56' \
    '2001:0db8:85a3:0000:0000:8a2e:0370:7334' \
    '10.77.0.4:9443' \
    '550e8400-e29b-41d4-a716-446655440000'; do
    grep -qF "$survivor" "$shape_dir/console" \
        || fail "the delimited-hex rule swallowed a diagnostic shape: '$survivor'"
done
! grep -qF '17:F2:A7:7C:75:9D:F0:84:9D' "$shape_dir/console" \
    || fail "a colon fingerprint survived among the diagnostic shapes"
! grep -qF 'de ad be ef de ad be ef' "$shape_dir/console" \
    || fail "an xxd-spaced hex run reached the console"
grep -qF 'does not match' "$shape_dir/console" \
    || fail "redacting the delimited token threw away the message around it"

echo "pki-authority-sync tests passed"
