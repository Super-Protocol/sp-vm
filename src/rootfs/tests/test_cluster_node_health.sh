#!/usr/bin/env bash

# SUP-376/SUP-419: scripts/azure/cluster.sh as a consumer of the guest's
# node-health rollup on :9180.
#
# SUP-370 was 25 hours of `up` waiting on a node that had already published,
# inside itself, that no retry could ever succeed. So the property under test
# is not "the column renders". It is the asymmetry the contract puts on this
# consumer, and every case below is one half of it:
#
#   - `blocked` ends a wait IMMEDIATELY, long before --node-timeout, and the
#     cause reaches the operator;
#   - nothing else ends a wait, and nothing at all ends one successfully.
#     `serving` does not stand in for the probe the wait actually makes, and
#     `unknown` - which is also what no answer on :9180 looks like - is not a
#     weaker `serving`. Treating silence as evidence is the original defect
#     moved one layer up, so it is pinned here as its own case.
#
# cluster.sh runs on an operator's host and is not installed into the rootfs, so
# unlike its neighbours here this suite has no src/Dockerfile counterpart - it
# runs from .github/workflows/rootfs-tests.yml against the repository tree and
# nowhere else.
#
# The endpoint is stubbed by a real HTTP server on a real socket, because two
# of the rules only exist at that level: the endpoint answers 200 on every
# verdict (so `curl --fail` distinguishes "gone" from "unhealthy" and nothing
# else), and a node that does not answer at all has to come out as `unknown`
# rather than as an error.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
cluster_sh="$repository_root/scripts/azure/cluster.sh"

test_root="$(mktemp -d -t sp-cluster-node-health.XXXXXXXX)"
stub_pid=""
cleanup() {
    [[ -n "$stub_pid" ]] && kill "$stub_pid" 2>/dev/null
    rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$cluster_sh" ]] || fail "$cluster_sh is missing"
for required in curl jq python3; do
    command -v "$required" >/dev/null 2>&1 || fail "$required is needed to run this suite"
done

health_file="$test_root/nodeHealth.json"
measure_file="$test_root/getMeasure.json"

# ===========================================================================
# The stub endpoint
# ===========================================================================

# Serves whatever the case last wrote, on the two route pairs :9180 really
# carries. An absent file is 503 and not a missing route: that is the endpoint
# being there while the verdict is not, which the contract separates from the
# endpoint being gone.
cat >"$test_root/stub.py" <<'PY'
#!/usr/bin/env python3
"""Stands in for :9180 on a node, for test_cluster_node_health.sh."""
import http.server
import os
import sys

HEALTH = os.environ["SP_STUB_HEALTH"]
MEASURE = os.environ["SP_STUB_MEASURE"]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - the name is BaseHTTPRequestHandler's
        if self.path in ("/v1/nodeHealth", "/api/v1/nodeHealth"):
            path = HEALTH
        elif self.path in ("/v1/getMeasure", "/api/v1/getMeasure"):
            path = MEASURE
        else:
            self.send_error(404)
            return
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except OSError:
            self.send_error(503)
            return
        # 200 on every verdict, by contract: a prober must not be able to read
        # the status line as the node's health.
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
sys.stdout.close()
server.serve_forever()
PY

SP_STUB_HEALTH="$health_file" SP_STUB_MEASURE="$measure_file" \
    python3 -I "$test_root/stub.py" >"$test_root/port" 2>"$test_root/stub.err" &
stub_pid=$!

for _ in $(seq 1 50); do
    stub_port="$(head -n1 "$test_root/port" 2>/dev/null || true)"
    [[ -n "${stub_port:-}" ]] && break
    sleep 0.1
done
[[ -n "${stub_port:-}" ]] || fail "the stub endpoint did not start: $(cat "$test_root/stub.err")"

# A port nothing listens on, for the probes a case needs to keep failing. Taken
# by binding and releasing, so it is not some other test's port.
closed_port="$(python3 -I -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

# ===========================================================================
# The driver: one fresh shell per case, with cluster.sh sourced into it
# ===========================================================================

cat >"$test_root/drive" <<'EOF'
#!/usr/bin/env bash
# Sources cluster.sh and calls one of its functions. Every port but the stub's
# points at nothing, so each wait's own probe keeps failing and what the case
# measures is purely what node health does to the wait.
source "$SP_CLUSTER_SH"
MEASURE_PORT="$SP_STUB_PORT"
PKI_PORT="$SP_CLOSED_PORT"
GOSSIP_PORT="$SP_CLOSED_PORT"
POLL_SECONDS=1
NODE_TIMEOUT="$SP_DEADLINE"
STATE_DIR="$SP_STATE_DIR"
function_name="$1"
shift
SECONDS=0
"$function_name" "$@"
EOF
chmod +x "$test_root/drive"

state_dir="$test_root/state"
mkdir -p "$state_dir"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcluster\n-----END CERTIFICATE-----\n' >"$state_dir/ca.pem"

# Runs one cluster.sh function under the stub. Prints the function's stderr on
# stdout and returns its exit code; how long it took goes to a file, because
# every case captures this in a command substitution and a variable set in
# that subshell would never reach the assertion - which would make each
# "aborted early" case pass for a wait that ran its whole budget.
drive() {
    local deadline="$1" started ended rc=0
    shift
    started=$SECONDS
    SP_CLUSTER_SH="$cluster_sh" SP_STUB_PORT="$stub_port" \
        SP_CLOSED_PORT="$closed_port" SP_DEADLINE="$deadline" \
        SP_STATE_DIR="$state_dir" \
        bash "$test_root/drive" "$@" >"$test_root/out" 2>"$test_root/err" || rc=$?
    ended=$SECONDS
    echo $((ended - started)) >"$test_root/elapsed"
    cat "$test_root/err"
    return "$rc"
}

# How long the last drive() took, in seconds.
elapsed() {
    cat "$test_root/elapsed"
}

# Writes the rollup document the next request will get.
set_health() {
    local state="$1" reason_class="$2" summary="$3" received="$4" expected="$5"
    jq -n --arg state "$state" --arg reason_class "$reason_class" \
        --arg summary "$summary" --arg received "$received" --arg expected "$expected" '
        {
          schema: "sp.node-health/v1",
          state: $state,
          reason_class: $reason_class,
          terminal: ($state == "blocked"),
          summary: $summary,
          uptime_sec: 91847,
          updated_at: "2026-10-19T17:04:11Z",
          units: [],
          attestation: {
            received_id_hex: (if $received == "" then null else $received end),
            expected_id_hex: (if $expected == "" then null else $expected end)
          }
        }' >"$health_file"
}

blocked_class="pki-authority-sync:http-403-unvalidated"
blocked_summary="the authority issued a certificate it will not accept; this node cannot join"
received_hex="a8426194c525e5729f6c1a4d3e8b7c5049d2f1a6b3c8e07d5241f9ab6c3d8e02"

no_health() { rm -f "$health_file"; }
no_measure() { rm -f "$measure_file"; }

# ===========================================================================
# read_node_health: what the rollup is allowed to mean
# ===========================================================================

probe_verdict() {
    SP_CLUSTER_SH="$cluster_sh" SP_STUB_PORT="$stub_port" \
        SP_CLOSED_PORT="$closed_port" SP_DEADLINE=1 SP_STATE_DIR="$state_dir" \
        bash -c '
            source "$SP_CLUSTER_SH"
            MEASURE_PORT="$SP_STUB_PORT"
            read_node_health 127.0.0.1
            printf "%s|%s|%s|%s|%s\n" "$HEALTH_STATE" "$HEALTH_REASON_CLASS" \
                "$HEALTH_RECEIVED_HEX" "$HEALTH_EXPECTED_HEX" "$HEALTH_SUMMARY"
        '
}

# Every state the vocabulary has must survive the round trip unchanged: a
# consumer that cannot tell `degraded` from `blocked` has lost the only fact
# that would have ended SUP-370.
for state in serving booting degraded blocked unknown; do
    set_health "$state" "some:class" "a summary" "" ""
    verdict="$(probe_verdict)"
    [[ "${verdict%%|*}" == "$state" ]] \
        || fail "read_node_health turned $state into ${verdict%%|*}"
done

# No answer on :9180 at all. This is `unknown` and nothing else - it is the
# expected state for up to ~20 min on a GPU node, and reading it as healthy is
# the defect this endpoint exists to remove.
no_health
verdict="$(probe_verdict)"
[[ "${verdict%%|*}" == "unknown" ]] \
    || fail "a node that does not answer on :9180 came out as ${verdict%%|*}, not unknown"

# A body this script cannot vouch for is also unknown, never the state word it
# happens to carry: an unauthenticated port is not a source of its own schema.
printf '%s' '{"schema":"sp.node-health/v99","state":"serving"}' >"$health_file"
[[ "$(probe_verdict)" == unknown\|* ]] \
    || fail "a document with an unknown schema was trusted: $(probe_verdict)"
printf '%s' 'not json at all' >"$health_file"
[[ "$(probe_verdict)" == unknown\|* ]] || fail "an unparseable body was trusted"
printf '%s' '{"schema":"sp.node-health/v1","state":"healthy"}' >"$health_file"
[[ "$(probe_verdict)" == unknown\|* ]] \
    || fail "a state word outside the vocabulary was passed through"

# These strings are printed straight to an operator's terminal and come from a
# port that is plain HTTP, unauthenticated and open to any source, so a node
# must not be able to put control characters on that terminal.
set_health blocked "x:y" "$(printf 'red \033[31m alert \007 and a tab \t here')" "" ""
verdict="$(probe_verdict)"
[[ "$verdict" != *$'\033'* && "$verdict" != *$'\007'* ]] \
    || fail "an escape sequence from the endpoint reached the terminal: $(cat -v <<<"$verdict")"
# Every byte outside printable ASCII becomes a question mark; what is left of
# the sequence is inert text. The escape introducer is what makes a terminal
# obey the rest, so removing it is the whole guard.
[[ "$verdict" == *"red ?[31m alert ? and a tab ? here"* ]] \
    || fail "the summary was not reduced to printable ASCII: $verdict"

# The two measurements have to look like measurements. Everything else is a
# dash, so a dash in the report never means "the node answered something".
set_health blocked "x:y" "s" "$received_hex" ""
verdict="$(probe_verdict)"
[[ "$verdict" == *"|${received_hex}|-|"* ]] \
    || fail "the measurement round trip is wrong: $verdict"
set_health blocked "x:y" "s" 'rm -rf /' ""
verdict="$(probe_verdict)"
[[ "$verdict" == *"|-|-|"* ]] || fail "a non-hex measurement was passed through: $verdict"

# ===========================================================================
# The behaviour change: `blocked` ends a wait at once
# ===========================================================================

# Generous on purpose. The old behaviour is to burn all of it, so a case that
# passes in a fraction of this deadline is the whole point; and the assertion
# is on the margin, not on a stopwatch, so a slow runner cannot fail it.
readonly long_deadline=60
readonly abort_margin=20

no_measure
set_health blocked "$blocked_class" "$blocked_summary" "$received_hex" ""

for wait_function in wait_measure wait_bootstrap_pki wait_joined; do
    report=""
    report="$(drive "$long_deadline" "$wait_function" node-1 127.0.0.1 "$long_deadline")" \
        && fail "$wait_function returned success for a node that reports blocked"
    (( $(elapsed) < abort_margin )) \
        || fail "$wait_function took $(elapsed)s of its ${long_deadline}s budget on a blocked node: it is still waiting out the timeout"
    [[ "$report" == *"Node node-1 failed"* ]] \
        || fail "$wait_function aborted without the failure report: $report"
    # reason_class and summary, not "no answer": the node said why, and the
    # point of reading it is that the operator gets that instead of a guess.
    [[ "$report" == *"$blocked_class"* ]] \
        || fail "$wait_function did not print reason_class: $report"
    [[ "$report" == *"$blocked_summary"* ]] \
        || fail "$wait_function did not print the summary: $report"
    [[ "$report" == *"$received_hex"* ]] \
        || fail "$wait_function did not print the measurement the node holds: $report"
    # expected_id_hex is null until the authority-side change lands (contract
    # §5), and that has to read as "not published", not as "none".
    [[ "$report" == *"mrEnclave wanted:"* && "$report" == *"not published by the authority yet"* ]] \
        || fail "$wait_function did not say why the accepted measurement is absent: $report"
    [[ "$report" == *"node health:      blocked"* ]] \
        || fail "$wait_function did not print the rollup state: $report"
    # The report must not claim the budget ran out: it did not, and in this
    # report the difference between the two is the whole finding.
    [[ "$report" == *"Stopped at once rather than waiting out --node-timeout"* ]] \
        || fail "$wait_function reported a blocked abort as a timeout: $report"
    [[ "$report" != *"Gave up after --node-timeout"* ]] \
        || fail "$wait_function said it gave up after the timeout it never reached: $report"
done

# Once the authority does publish it, both values appear - the one fact that
# turns "this node is not accepted" into "this node is build-448 and the cloud
# wants another".
expected_hex="3b87e54d9c1759584c2a7e6b1d0f9382a5c4e7b6d9f10283746556473829100ab"
set_health blocked "$blocked_class" "$blocked_summary" "$received_hex" "$expected_hex"
report="$(drive "$long_deadline" wait_measure node-1 127.0.0.1 "$long_deadline")" \
    && fail "wait_measure returned success for a blocked node"
[[ "$report" == *"$received_hex"* && "$report" == *"$expected_hex"* ]] \
    || fail "node_failed printed one measurement but not both: $report"

# ===========================================================================
# The other half: nothing but `blocked` ends a wait, and nothing ends one well
# ===========================================================================

# Short, because each of these has to run its deadline out to pass.
readonly short_deadline=4

# `serving` is the dangerous one. It is the only state that is positive
# evidence of anything, and a consumer that accepts it in place of its own
# probe is how a wait starts passing for a node that cannot serve it.
no_measure
set_health serving "node-serving:serving" "this node reports a fresh local witness that it serves" "" ""
report="$(drive "$short_deadline" wait_measure node-1 127.0.0.1 "$short_deadline")" \
    && fail "wait_measure succeeded on health=serving without the Measurement API answering"
(( $(elapsed) >= short_deadline )) \
    || fail "wait_measure gave up after $(elapsed)s instead of waiting out its ${short_deadline}s budget on health=serving"

# `degraded` keeps waiting inside the existing timeout. Collapsing it into
# `blocked` would make a retryable failure delete a node.
set_health degraded "pki-authority-sync:timeout" "pki-authority-sync.service failed on a retryable cause; this node is not serving" "" ""
report="$(drive "$short_deadline" wait_bootstrap_pki node-1 127.0.0.1 "$short_deadline")" \
    && fail "wait_bootstrap_pki returned success on health=degraded"
(( $(elapsed) >= short_deadline )) \
    || fail "wait_bootstrap_pki ended a wait on health=degraded after $(elapsed)s"
[[ "$report" == *"node health:      degraded"* ]] \
    || fail "a degraded node's state did not surface in the report: $report"

# `unknown`, and silence, are not reasons to stop either. A wait that aborted
# here would delete nodes for a :9180 that is merely slow, which is the mirror
# image of the SUP-370 bug and just as bad.
for scenario in explicit-unknown no-answer; do
    if [[ "$scenario" == explicit-unknown ]]; then
        set_health unknown "" "no verdict has been published yet; this is not evidence of serving" "" ""
    else
        no_health
    fi
    report="$(drive "$short_deadline" wait_joined node-1 127.0.0.1 "$short_deadline")" \
        && fail "wait_joined returned success with health unknown ($scenario)"
    (( $(elapsed) >= short_deadline )) \
        || fail "wait_joined stopped waiting after $(elapsed)s with health unknown ($scenario)"
    [[ "$report" == *"node health:      unknown"* ]] \
        || fail "the report did not name the node's health as unknown ($scenario): $report"
    # And this one did run out of time, so it has to say so.
    [[ "$report" == *"Gave up after --node-timeout"* ]] \
        || fail "a wait that ran its budget out did not report it as a timeout ($scenario): $report"
done

# And the probe still decides. A node whose Measurement API answers passes
# wait_measure even while the rollup vetoes it - the veto belongs to the waits
# that come after, each of which checks it at its own layer.
printf '%s' '{"type":"tdx-azure","mrenclaveHex":"3b87e54d9c175958"}' >"$measure_file"
set_health blocked "$blocked_class" "$blocked_summary" "$received_hex" ""
drive "$long_deadline" wait_measure node-1 127.0.0.1 "$long_deadline" \
    || fail "wait_measure failed even though the Measurement API answered: $(cat "$test_root/err")"
grep -q 'tdx-azure	3b87e54d9c175958' "$state_dir/mrenclave.log" \
    || fail "wait_measure did not record the measurement it read"

# ===========================================================================
# status_table: the column, and the one verdict that gets its own warning
# ===========================================================================

# Everything status_table asks Azure for is stubbed; read_node_health is the
# real one and answers from the stub endpoint, which is the part under test.
cat >"$test_root/drive-status" <<'EOF'
#!/usr/bin/env bash
source "$SP_CLUSTER_SH"
MEASURE_PORT="$SP_STUB_PORT"
CLUSTER=azure-test
STATE_DIR="$SP_STATE_DIR"
LAUNCHER=./run_custom_conf_vm.sh

cluster_groups() {
  printf 'sp-vm-azure-test-node-1-mct4\tazure-test-node-1-mct4\t1\tbootstrap\tbuild-448-release\n'
}
az() { printf 'Standard_DC8es_v6\nwestus3\n3\n127.0.0.1\n'; }
get_measure() { echo "tdx-azure 3b87e54d9c1759584c2a7e6b1d0f9382"; }
registry_has() { return 0; }
ca_matches() { return 0; }
config_state() { echo ok; }
ui_ready() { UI_STATE="stubbed"; return 1; }

status_table
EOF

status_table_output() {
    SP_CLUSTER_SH="$cluster_sh" SP_STUB_PORT="$stub_port" SP_STATE_DIR="$state_dir" \
        bash "$test_root/drive-status" 2>&1
}

# The column sits with the other verdicts about the node, and CONFIG stays
# last: an operator reads these left to right and CA/HEALTH belong together.
set_health degraded "pki-authority-sync:timeout" "pki-authority-sync.service failed on a retryable cause; this node is not serving" "" ""
table="$(status_table_output)"
[[ "$table" == *"CA"*"HEALTH"*"CONFIG"* ]] \
    || fail "the HEALTH column is not in the header between CA and CONFIG: $table"
[[ "$table" =~ azure-test-node-1-mct4[[:space:]].*[[:space:]]yes[[:space:]]+ok[[:space:]]+degraded[[:space:]]+ok ]] \
    || fail "the row does not carry the rollup in the HEALTH column: $table"
[[ "$table" != *"HEALTH=blocked"* ]] \
    || fail "a degraded node raised the blocked warning"

# A node that cannot be fixed by waiting is the one case where a word in a
# column is not enough: status is also what someone runs on a cluster that has
# been stuck for hours, and this is the line that ends it.
set_health blocked "$blocked_class" "$blocked_summary" "$received_hex" ""
table="$(status_table_output)"
[[ "$table" =~ azure-test-node-1-mct4[[:space:]].*[[:space:]]blocked[[:space:]]+ok ]] \
    || fail "a blocked node does not show as blocked in the table: $table"
[[ "$table" == *"1 node(s) report HEALTH=blocked"* ]] \
    || fail "the blocked warning is missing: $table"
[[ "$table" == *"$blocked_class"* && "$table" == *"$blocked_summary"* ]] \
    || fail "the blocked warning does not name the cause: $table"
[[ "$table" == *"Waiting will not clear this"* ]] \
    || fail "the blocked warning does not say that waiting is pointless: $table"

# And a node that answers nothing on :9180 is `unknown` here too, with no
# warning: this table must not accuse a node of being blocked because this
# host could not reach it.
no_health
table="$(status_table_output)"
[[ "$table" =~ azure-test-node-1-mct4[[:space:]].*[[:space:]]unknown[[:space:]]+ok ]] \
    || fail "a node that does not answer on :9180 is not unknown in the table: $table"
[[ "$table" != *"HEALTH=blocked"* ]] \
    || fail "an unreachable endpoint raised the blocked warning"

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
