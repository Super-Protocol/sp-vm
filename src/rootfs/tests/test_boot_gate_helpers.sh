#!/usr/bin/env bash

# SUP-375: the two per-unit scripts that replaced an unbounded `until` loop in a
# unit file. Both exist so the attempt they make is bounded and reportable - and
# both have a failure mode the loop they replaced did not, so both are pinned
# here.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_BOOT_GATE_HELPERS_TEST_INSTALLED_ROOT:-}" ]]; then
    bin_dir="$SP_BOOT_GATE_HELPERS_TEST_INSTALLED_ROOT/usr/local/bin"
else
    bin_dir="$repository_root/src/rootfs/files/configs/usr/local/bin"
fi
vm_mode="$bin_dir/pki-vm-mode.sh"
cert_init="$bin_dir/pki-cert-init.sh"

test_root="$(mktemp -d -t sp-boot-gate-helpers.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

# Every case below redirects the script under test, and `bounded` reports
# through fail() from inside that redirection - so fail() keeps its own handle
# on the real stderr, or a verdict would land in the case's output file and the
# suite would exit 1 with nothing to show.
exec {real_stderr}>&2
fail() {
    echo "FAIL: $*" >&"$real_stderr"
    exit 1
}

[[ -x "$vm_mode" ]] || fail "pki-vm-mode.sh is missing or not executable"
[[ -x "$cert_init" ]] || fail "pki-cert-init.sh is missing or not executable"

# Every script under test runs behind a deadline of its own. The property being
# tested is "this terminates", and a test that demonstrates the absence of that
# property by hanging demonstrates nothing - it just wedges the build.
readonly case_deadline="${SP_BOOT_GATE_HELPERS_DEADLINE:-30}"
bounded() {
    local rc
    timeout --kill-after=5s "${case_deadline}s" "$@"
    rc=$?
    (( rc == 124 || rc == 137 )) \
        && fail "${*: -1} did not terminate within ${case_deadline}s: the wait is unbounded again"
    return "$rc"
}

# Records its argv and obeys SP_TEST_RC, so each case can say which step fails.
cat >"$test_root/fake-tool" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$SP_TEST_ARGV_LOG"
exit "${SP_TEST_RC:-0}"
EOF
chmod +x "$test_root/fake-tool"

# --- pki-vm-mode.sh: the wait for /sp must end ---

# The SUP-343 case: provider-config.service cannot populate /sp, so the config
# never arrives. The old ExecStartPre looped on it forever under
# TimeoutStartSec=infinity and held multi-user.target with it.
gone_dir="$test_root/vm-mode-config-gone"
mkdir -p "$gone_dir"
started="$SECONDS"
bounded env \
    SP_VM_MODE_CONFIG="$gone_dir/config.yaml" \
    SP_VM_MODE_OUTPUT="$gone_dir/vm-mode" \
    SP_VM_MODE_PYTHON="$test_root/fake-tool" \
    SP_VM_MODE_HELPER="helper.py" \
    SP_VM_MODE_CONFIG_WAIT=2 \
    SP_VM_MODE_POLL_INTERVAL=1 \
    SP_TEST_ARGV_LOG="$gone_dir/argv.log" \
    "$vm_mode" >"$gone_dir/stdout" 2>"$gone_dir/stderr"
rc=$?
elapsed=$((SECONDS - started))
(( rc == 69 )) || fail "a config that never arrives exited $rc, not 69 (EX_UNAVAILABLE)"
(( elapsed < 20 )) || fail "the wait for /sp took ${elapsed}s to give up on a 2s bound"
grep -q 'provider-config.service has not populated /sp' "$gone_dir/stderr" \
    || fail "the verdict does not name the service that owns /sp: $(cat "$gone_dir/stderr")"
[[ ! -s "$gone_dir/argv.log" ]] || fail "the helper ran against a config that is not there"

# An empty file is not a config: /sp is populated by an archive extraction, so a
# zero-length config.yaml is a half-written one.
empty_dir="$test_root/vm-mode-config-empty"
mkdir -p "$empty_dir"
: >"$empty_dir/config.yaml"
bounded env \
    SP_VM_MODE_CONFIG="$empty_dir/config.yaml" \
    SP_VM_MODE_OUTPUT="$empty_dir/vm-mode" \
    SP_VM_MODE_PYTHON="$test_root/fake-tool" \
    SP_VM_MODE_HELPER="helper.py" \
    SP_VM_MODE_CONFIG_WAIT=1 \
    SP_VM_MODE_POLL_INTERVAL=1 \
    SP_TEST_ARGV_LOG="$empty_dir/argv.log" \
    "$vm_mode" >/dev/null 2>&1
(( $? == 69 )) || fail "an empty config.yaml was treated as a usable one"

# The ordinary case the bounded wait exists for: /sp lands a moment after this
# unit starts, and the attempt must absorb that without failing the unit.
late_dir="$test_root/vm-mode-config-late"
mkdir -p "$late_dir"
( sleep 2; printf 'swarm: {}\n' >"$late_dir/config.yaml" ) &
late_writer=$!
bounded env \
    SP_VM_MODE_CONFIG="$late_dir/config.yaml" \
    SP_VM_MODE_OUTPUT="$late_dir/vm-mode" \
    SP_VM_MODE_PYTHON="$test_root/fake-tool" \
    SP_VM_MODE_HELPER="helper.py" \
    SP_VM_MODE_CONFIG_WAIT=20 \
    SP_VM_MODE_POLL_INTERVAL=1 \
    SP_TEST_ARGV_LOG="$late_dir/argv.log" \
    "$vm_mode" >"$late_dir/stdout" 2>"$late_dir/stderr" \
    || fail "a config that arrives during the wait was not picked up"
wait "$late_writer" 2>/dev/null
grep -q -- "get-vm-mode --config $late_dir/config.yaml --output $late_dir/vm-mode" "$late_dir/argv.log" \
    || fail "the helper was not pointed at the config and output the unit expects: $(cat "$late_dir/argv.log")"

# A helper that fails has to fail the attempt: this is the unit whose output
# tells pki-cert-init and pki-authority-sync what this node is.
broken_dir="$test_root/vm-mode-helper-broken"
mkdir -p "$broken_dir"
printf 'swarm: {}\n' >"$broken_dir/config.yaml"
bounded env \
    SP_VM_MODE_CONFIG="$broken_dir/config.yaml" \
    SP_VM_MODE_OUTPUT="$broken_dir/vm-mode" \
    SP_VM_MODE_PYTHON="$test_root/fake-tool" \
    SP_VM_MODE_HELPER="helper.py" \
    SP_TEST_RC=255 \
    SP_TEST_ARGV_LOG="$broken_dir/argv.log" \
    "$vm_mode" >/dev/null 2>&1
(( $? == 255 )) || fail "the helper's exit code did not reach the unit"

# --- pki-cert-init.sh: the configure step is no longer a blind spot ---

# As an ExecStartPre this failure produced no console block at all: the unit
# failed before ExecStart ran, so the runner never saw it. On a seed that is the
# whole cloud going quiet.
cfg_dir="$test_root/cert-init-configure-fails"
mkdir -p "$cfg_dir"
bounded env \
    SP_PKI_CERT_INIT_PYTHON="$test_root/fake-tool" \
    SP_PKI_CERT_INIT_HELPER="helper.py" \
    SP_PKI_CERT_INIT_TEMPLATE="$cfg_dir/template.yaml" \
    SP_PKI_CERT_INIT_CONFIG="$cfg_dir/rendered.yaml" \
    SP_PKI_CERT_INIT_GENERATOR="$test_root/fake-tool" \
    SP_TEST_RC=1 \
    SP_TEST_ARGV_LOG="$cfg_dir/argv.log" \
    "$cert_init" >"$cfg_dir/stdout" 2>"$cfg_dir/stderr"
rc=$?
(( rc == 78 )) || fail "a failed configure exited $rc, not 78 (EX_CONFIG)"
grep -q "could not render $cfg_dir/rendered.yaml" "$cfg_dir/stderr" \
    || fail "a failed configure does not name the file it could not render"
[[ "$(grep -c . "$cfg_dir/argv.log")" == "1" ]] \
    || fail "the generator ran on top of a config that was never rendered"

# The happy path has to reach the generator with the rendered config, or the
# unit would succeed without a chain.
gen_dir="$test_root/cert-init-generates"
mkdir -p "$gen_dir"
bounded env \
    SP_PKI_CERT_INIT_PYTHON="$test_root/fake-tool" \
    SP_PKI_CERT_INIT_HELPER="helper.py" \
    SP_PKI_CERT_INIT_TEMPLATE="$gen_dir/template.yaml" \
    SP_PKI_CERT_INIT_CONFIG="$gen_dir/rendered.yaml" \
    SP_PKI_CERT_INIT_GENERATOR="$test_root/fake-tool" \
    SP_TEST_ARGV_LOG="$gen_dir/argv.log" \
    "$cert_init" >/dev/null 2>&1 \
    || fail "the happy path did not exit 0"
grep -q -- "configure --template $gen_dir/template.yaml --output $gen_dir/rendered.yaml" "$gen_dir/argv.log" \
    || fail "the configure step lost its arguments: $(cat "$gen_dir/argv.log")"
grep -q -- "generate-chain -c $gen_dir/rendered.yaml --log-level debug" "$gen_dir/argv.log" \
    || fail "the generator was not run against the rendered config: $(cat "$gen_dir/argv.log")"

# A refused chain is the SUP-372 shape on the seed side: it must fail, not loop,
# and the generator's own error has to survive for the runner to print.
refused_dir="$test_root/cert-init-refused"
mkdir -p "$refused_dir"
cat >"$test_root/fake-generator" <<'EOF'
#!/bin/bash
echo "ERROR: chain generation refused: unknown CA" >&2
exit 7
EOF
chmod +x "$test_root/fake-generator"
bounded env \
    SP_PKI_CERT_INIT_PYTHON="$test_root/fake-tool" \
    SP_PKI_CERT_INIT_HELPER="helper.py" \
    SP_PKI_CERT_INIT_TEMPLATE="$refused_dir/template.yaml" \
    SP_PKI_CERT_INIT_CONFIG="$refused_dir/rendered.yaml" \
    SP_PKI_CERT_INIT_GENERATOR="$test_root/fake-generator" \
    SP_TEST_ARGV_LOG="$refused_dir/argv.log" \
    "$cert_init" >"$refused_dir/stdout" 2>"$refused_dir/stderr"
(( $? == 7 )) || fail "the generator's exit code did not reach the unit"
grep -q 'chain generation refused' "$refused_dir/stderr" \
    || fail "the generator's own error was swallowed before the runner could print it"

echo "boot-gate helper tests passed"
