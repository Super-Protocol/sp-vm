#!/usr/bin/env bash
# Unit tests for sp-cni-after-wg0 and its systemd wiring (SUP-350/SUP-355).
#
# Runs with stub `ip`/`crictl`/`logger` on PATH, so it needs neither a running
# CNI nor root. Invoked from src/Dockerfile against the installed rootfs
# (SP_CNI_TEST_INSTALLED_ROOT) and runnable by hand against the repo tree.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_CNI_TEST_INSTALLED_ROOT:-}" ]]; then
    bin_dir="$SP_CNI_TEST_INSTALLED_ROOT/usr/local/bin"
    unit_dir="$SP_CNI_TEST_INSTALLED_ROOT/etc/systemd/system"
    timer_link="$unit_dir/timers.target.wants/sp-cni-after-wg0.timer"
else
    config_dir="$repository_root/src/rootfs/files/configs"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/etc/systemd/system"
    timer_link=""
fi
SUT="$bin_dir/sp-cni-after-wg0"

test_root="$(mktemp -d -t sp-cni-after-wg0.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

# --- packaging assertions ---------------------------------------------------

[[ -x "$SUT" ]] || fail "sp-cni-after-wg0 is missing or not executable at $SUT"
dropin="$unit_dir/wg-quick@wg0.service.d/10-cni-recovery.conf"
[[ -f "$dropin" ]] || fail "wg-quick@wg0 drop-in is missing at $dropin"
# `-` prefix: a failed CNI recovery must never fail or block wg-quick@wg0.
grep -qx 'ExecStartPost=-/usr/local/bin/sp-cni-after-wg0 wg0' "$dropin" \
    || fail "drop-in must call the helper from a failure-tolerant ExecStartPost=-"
# The hook waits inside the unit's start; without headroom a slow rebuild would
# time the unit out, and systemd would stop it — deleting wg0.
dropin_timeout=$(sed -n 's/^TimeoutStartSec=\([0-9]\+\)$/\1/p' "$dropin")
[[ -n "$dropin_timeout" ]] || fail "drop-in must set an explicit TimeoutStartSec"
default_wait=$(sed -n 's/^WAIT_SEC="${SP_CNI_WAIT_SEC:-\([0-9]\+\)}"$/\1/p' "$SUT")
[[ -n "$default_wait" ]] || fail "cannot read the helper's default wait budget"
if [[ -n "$dropin_timeout" && -n "$default_wait" ]]; then
    (( dropin_timeout > default_wait )) \
        || fail "TimeoutStartSec=$dropin_timeout must exceed the ${default_wait}s wait budget"
fi
grep -qx 'ExecStart=/usr/local/bin/sp-cni-after-wg0 wg0' "$unit_dir/sp-cni-after-wg0.service" \
    || fail "sp-cni-after-wg0.service must run the same helper"
grep -qx 'ConditionPathExists=/sys/class/net/wg0' "$unit_dir/sp-cni-after-wg0.service" \
    || fail "the timer's service must no-op while wg0 does not exist"
grep -qx 'OnUnitActiveSec=60' "$unit_dir/sp-cni-after-wg0.timer" \
    || fail "the timer must run every 60s"
if [[ -n "$timer_link" ]]; then
    [[ -L "$timer_link" ]] || fail "the timer is not enabled (missing $timer_link)"
fi

# --- behaviour --------------------------------------------------------------

stub_dir="$test_root/bin"
mkdir -p "$stub_dir"

# `ip link show <dev>` succeeds when the test created a marker for <dev>.
cat > "$stub_dir/ip" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == link && "$2" == show ]] || exit 64
[[ -e "$SP_TEST_STATE/dev-$3" ]]
EOF

# crictl: lists a running kube-flannel container, and `stop` optionally makes
# flannel.1 reappear (what a flanneld restart does on a real node).
cat > "$stub_dir/crictl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SP_TEST_STATE/crictl.log"
case "$1" in
    ps) [[ -e "$SP_TEST_STATE/no-container" ]] || echo 3039776abcdef0123456 ;;
    stop)
        [[ -e "$SP_TEST_STATE/rebuild-fails" ]] || touch "$SP_TEST_STATE/dev-flannel.1"
        ;;
esac
EOF

cat > "$stub_dir/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$stub_dir"/*

run_case() {
    # run_case <name>; the caller prepares $state beforehand
    state="$test_root/state-$1"
    mkdir -p "$state"
    shift
    env PATH="$stub_dir:$PATH" SP_TEST_STATE="$state" \
        SP_CNI_STATE_DIR="$state" SP_CNI_CRICTL="$stub_dir/crictl" \
        SP_CNI_WAIT_SEC="${WAIT_OVERRIDE:-10}" \
        "$@" "$SUT" wg0 > "$state/out" 2>&1
    echo $? > "$state/rc"
}

expect_rc() {
    local state="$test_root/state-$1" want="$2"
    local got; got=$(cat "$state/rc")
    [[ "$got" == "$want" ]] || { fail "$1: exit $got, want $want ($(tail -1 "$state/out"))"; return 1; }
    ok "$1: exit $want"
}

expect_stops() {
    local state="$test_root/state-$1" want="$2"
    local got; got=$(grep -c '^stop ' "$state/crictl.log" 2>/dev/null || true)
    [[ "${got:-0}" == "$want" ]] || fail "$1: $got crictl stop(s), want $want"
}

# wg0 absent (boot, or a node without the mesh): nothing to do.
run_case iface-absent
expect_rc iface-absent 0 && expect_stops iface-absent 0

# Both devices present: the common case, every tick of the timer.
state="$test_root/state-healthy"; mkdir -p "$state"
touch "$state/dev-wg0" "$state/dev-flannel.1"
run_case healthy
expect_rc healthy 0 && expect_stops healthy 0

# CNI not up yet: wg0 exists, no flannel container to restart.
state="$test_root/state-no-cni"; mkdir -p "$state"
touch "$state/dev-wg0" "$state/no-container"
run_case no-cni
expect_rc no-cni 0 && expect_stops no-cni 0

# crictl not installed (a node that never ran RKE2).
state="$test_root/state-no-crictl"; mkdir -p "$state"
touch "$state/dev-wg0"
run_case no-crictl SP_CNI_CRICTL="$test_root/nope"
expect_rc no-crictl 0 && expect_stops no-crictl 0

# The real thing: wg0 came back without flannel.1.
state="$test_root/state-recover"; mkdir -p "$state"
touch "$state/dev-wg0"
run_case recover
expect_rc recover 0 && expect_stops recover 1
grep -q 'flannel.1 restored' "$test_root/state-recover/out" \
    || fail "recover: the helper did not report flannel.1 restored"

# Repeated bounces are not throttled: a second removal recovers immediately.
rm -f "$test_root/state-recover/dev-flannel.1"
run_case recover
expect_rc recover 0 && expect_stops recover 2

# Rebuild fails: exit 1 (tolerated by ExecStartPost=-) and back off afterwards,
# instead of restarting flanneld every time the timer fires.
state="$test_root/state-backoff"; mkdir -p "$state"
touch "$state/dev-wg0" "$state/rebuild-fails"
WAIT_OVERRIDE=1 run_case backoff
expect_rc backoff 1 && expect_stops backoff 1
[[ -s "$test_root/state-backoff/sp-cni-after-wg0.failed-at" ]] \
    || fail "backoff: no failure timestamp recorded"
WAIT_OVERRIDE=1 run_case backoff
expect_rc backoff 0 && expect_stops backoff 1
# ... and retry once the backoff window has passed.
echo $(( $(date +%s) - 400 )) > "$test_root/state-backoff/sp-cni-after-wg0.failed-at"
WAIT_OVERRIDE=1 run_case backoff
expect_rc backoff 1 && expect_stops backoff 2
# A later success clears the failure state.
rm -f "$test_root/state-backoff/rebuild-fails" "$test_root/state-backoff/dev-flannel.1"
echo "$(date +%s)" > "$test_root/state-backoff/sp-cni-after-wg0.failed-at"
touch "$test_root/state-backoff/dev-flannel.1"
run_case backoff
expect_rc backoff 0
[[ -e "$test_root/state-backoff/sp-cni-after-wg0.failed-at" ]] \
    && fail "backoff: failure timestamp survived a healthy run"

# The timer must not fight an ExecStartPost run that is already recovering.
state="$test_root/state-locked"; mkdir -p "$state"
touch "$state/dev-wg0"
if command -v flock >/dev/null 2>&1; then
    flock "$state/sp-cni-after-wg0.lock" sleep 5 &
    locker=$!
    sleep 0.3
    run_case locked
    expect_rc locked 0 && expect_stops locked 0
    wait "$locker" 2>/dev/null
else
    echo "skip: flock not available"
fi

if (( failures > 0 )); then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "all sp-cni-after-wg0 tests passed"
