#!/usr/bin/env bash

# SUP-372: pki-authority-sync must never become a boot gate again. Everything
# here is a regression guard for one of the three defects of the old unit - an
# unbounded TimeoutStartSec, a retry loop inside ExecStart, and a failure that
# left no trace a -release guest could show.

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

test_root="$(mktemp -d -t sp-pki-authority-sync.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

unit_value() {
    sed -n "s/^$1=//p" "$unit" | tail -n1
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
    SP_PKI_SYNC_CLIENT="$case_dir/client.js" \
    SP_PKI_SYNC_SECRETS_CONFIG="$case_dir/secrets.yaml" \
    SP_PKI_SYNC_SWARM_ENV="$case_dir/swarm-env.yaml" \
    SP_PKI_SYNC_CERTS_DIR="$case_dir/certs" \
    SP_PKI_SYNC_NETWORK_TYPE_FILE="$case_dir/network-type" \
    SP_PKI_SYNC_STATE_DIR="$case_dir/state" \
    SP_PKI_SYNC_CONSOLE="$case_dir/console" \
    SP_PKI_SYNC_ATTEMPT_TIMEOUT="$attempt_timeout_override" \
    SP_TEST_NODE_BEHAVIOUR="$behaviour" \
    SP_TEST_NODE_ARGV_LOG="$case_dir/argv.log" \
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

echo "pki-authority-sync tests passed"
