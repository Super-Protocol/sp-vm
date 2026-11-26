#!/usr/bin/env bash

# SUP-949: the one CA probe in scripts/azure/cluster.sh whose negative answer
# is acted upon immediately, instead of being polled until --node-timeout.
#
# The bug this pins: during the SUP-947 bring-up, `up` fetched the bootstrap's
# CA, verified it, saved it - and five seconds later died with "No cluster node
# serves the cluster CA; cannot add a node". Nothing had changed; probed by
# hand right afterwards the node served a byte-identical CA. One `curl` had
# failed, and because `live_peers` asked once, that single failure became the
# verdict for the whole cluster and ended the run.
#
# So the property under test is the asymmetry a terminal probe has to have:
#
#   - a positive answer still decides at once. No retry window is spent on a
#     node that serves, and nothing weakens what "serves" means: a node that
#     answers with ANOTHER CA is not a peer, however many times it is asked;
#   - a negative answer is only believed after the probe has kept failing for
#     a bounded window - and the window is bounded, so a cluster that really
#     has no CA still fails, with an error that names the probe rather than
#     accusing the cluster.
#
# The seams stubbed here are `curl` and `az`, not cluster.sh's own functions:
# fetch_ca / ca_matches / node_ip / peer_serving_ca / live_peers / join_node
# all run as shipped, and what the stubs decide is only what the network and
# the Azure control plane answer on each attempt.
#
# cluster.sh runs on an operator's host and is not installed into the rootfs,
# so like test_cluster_node_health.sh this suite has no src/Dockerfile
# counterpart - it runs from .github/workflows/rootfs-tests.yml against the
# repository tree and nowhere else.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
cluster_sh="$repository_root/scripts/azure/cluster.sh"

test_root="$(mktemp -d -t sp-cluster-ca-reprobe.XXXXXXXX)"
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$cluster_sh" ]] || fail "$cluster_sh is missing"

plans="$test_root/plans"
state_dir="$test_root/state"
mkdir -p "$plans" "$state_dir"

printf -- '-----BEGIN CERTIFICATE-----\nMIIBcluster\n-----END CERTIFICATE-----\n' >"$state_dir/ca.pem"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBanother\n-----END CERTIFICATE-----\n' >"$plans/other-ca.pem"

# Generous enough that "waited the window out" and "returned as soon as the
# probe succeeded" cannot be confused on a slow runner, short enough to keep
# the suite in seconds.
readonly window=6

# ===========================================================================
# The driver: one fresh shell per case, with cluster.sh sourced into it
# ===========================================================================
#
# A plan is one file per node (addresses) or per address (CA answers), one word
# per attempt, consumed in order; once a plan runs out its last word repeats,
# so "always fails" is a one-line plan. The counter lives in a file because
# every probe here runs inside a command substitution - a counter in a
# variable would reset on each attempt and no case could ever fail.
cat >"$test_root/drive" <<'EOF'
#!/usr/bin/env bash
source "$SP_CLUSTER_SH"

CLUSTER=ca-test
STATE_DIR="$SP_STATE_DIR"
PKI_PORT=9443
CA_REPROBE_SECONDS="$SP_WINDOW"
CA_REPROBE_POLL_SECONDS=1
POLL_SECONDS=1
NODE_TIMEOUT=5

plan_step() {
    local file="$1" counter="$1.n" i steps=()
    [[ -f "$file" ]] || { echo "__noplan__"; return 0; }
    mapfile -t steps <"$file"
    (( ${#steps[@]} )) || { echo "__noplan__"; return 0; }
    i="$(cat "$counter" 2>/dev/null || echo 0)"
    echo $((i + 1)) >"$counter"
    (( i < ${#steps[@]} )) || i=$(( ${#steps[@]} - 1 ))
    echo "${steps[i]}"
}

# The PKI endpoint, as fetch_ca's curl sees it: nothing on stdout and a
# non-zero status when the request fails, the certificate body when it does
# not.
curl() {
    local arg url="" hostport ip step
    for arg in "$@"; do
        [[ "$arg" == https://* ]] && url="$arg"
    done
    [[ -n "$url" ]] || { echo "the stub was asked for an unexpected URL: $*" >&2; return 99; }
    hostport="${url#https://}"
    ip="${hostport%%:*}"
    step="$(plan_step "${SP_PLANS}/ca.${ip}")"
    printf 'ca %s %s\n' "$ip" "$step" >>"${SP_PLANS}/probes.log"
    case "$step" in
        cluster) cat "${STATE_DIR}/ca.pem" ;;
        other) cat "${SP_PLANS}/other-ca.pem" ;;
        fail) return 7 ;;
        *) echo "no CA plan for ${ip}" >&2; return 99 ;;
    esac
}

# The Azure control plane, for the two lookups these paths make: the node's
# public address, and whether a generated name is free.
az() {
    local arg prev="" name="" step
    if [[ "${1:-} ${2:-}" == "group exists" ]]; then
        echo false
        return 0
    fi
    for arg in "$@"; do
        [[ "$prev" == "-n" ]] && name="$arg"
        prev="$arg"
    done
    step="$(plan_step "${SP_PLANS}/ip.${name}")"
    printf 'ip %s %s\n' "$name" "$step" >>"${SP_PLANS}/probes.log"
    case "$step" in
        # `az` itself failing is the same single-shot "no" as a failed probe:
        # node_ip swallows the error and prints nothing.
        none) return 1 ;;
        __noplan__) echo "no address plan for ${name}" >&2; return 1 ;;
        *) echo "$step" ;;
    esac
}

cluster_groups() { cat "${SP_PLANS}/groups.tsv"; }

# join_node beyond the probe under test: the node is new, its creation and the
# waits that follow are not what this suite measures.
vm_exists() { return 1; }
new_node_name() { echo "ca-test-node-$1-aaaa"; }
render_node() { echo "swarm.example.com"; }
launch_node() { echo "10.0.0.9"; }
wait_measure() { MEASURE_TYPE="tdx-azure"; MEASURE_HEX="3b87e54d9c175958"; return 0; }
wait_registry() { return 0; }
wait_joined() { return 0; }

function_name="$1"
shift
SECONDS=0
"$function_name" "$@"
EOF
chmod +x "$test_root/drive"

# Runs one cluster.sh function under the stubs. Its stdout (the peer addresses)
# is returned; its stderr (the log) and how long it took go to files, because
# each case reads this in a command substitution and a variable set in that
# subshell would never reach the assertion.
drive() {
    local started ended rc=0
    started=$SECONDS
    SP_CLUSTER_SH="$cluster_sh" SP_STATE_DIR="$state_dir" SP_PLANS="$plans" \
        SP_WINDOW="$window" \
        bash "$test_root/drive" "$@" 2>"$test_root/err" || rc=$?
    ended=$SECONDS
    echo $((ended - started)) >"$test_root/elapsed"
    return "$rc"
}

# `live_peers` answers on stdout, one address per serving node, and its exit
# status is only whatever its last probe happened to return - so every case
# below asserts on the addresses and ignores the status, exactly as its callers
# (`mapfile < <(live_peers ...)`) do.
logged() { cat "$test_root/err"; }
elapsed() { cat "$test_root/elapsed"; }

# Starts a case from a clean slate: no plans, no counters, no probe log.
reset_plans() {
    rm -f "$plans"/ca.* "$plans"/ip.* "$plans/probes.log" "$plans/groups.tsv"
    : >"$plans/probes.log"
}

# One cluster node: <name> <address>, in the tab-separated shape
# cluster_groups prints.
groups_line() {
    printf 'sp-vm-%s\t%s\t%s\t%s\tbuild-488-release\n' "$1" "$1" "$3" "$4" >>"$plans/groups.tsv"
    printf '%s\n' "$2" >"$plans/ip.$1"
}

probes_for() { grep -c "^ca $1 " "$plans/probes.log" || true; }

# ===========================================================================
# A node that serves is a peer at once
# ===========================================================================

reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'cluster\n' >"$plans/ca.10.0.0.1"
peers="$(drive live_peers "" || true)"
[[ "$peers" == "10.0.0.1" ]] || fail "live_peers did not return the serving node: '$peers'"
(( $(elapsed) <= 2 )) \
    || fail "live_peers spent $(elapsed)s on a node that answered its first probe"
(( $(probes_for 10.0.0.1) == 1 )) \
    || fail "a node that served its first probe was asked $(probes_for 10.0.0.1) times"
[[ "$(logged)" != *"re-probing"* ]] \
    || fail "a successful first probe still announced a retry: $(logged)"

# ===========================================================================
# The regression: a probe that fails and then succeeds is not a verdict
# ===========================================================================

reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'fail\nfail\ncluster\n' >"$plans/ca.10.0.0.1"
peers="$(drive live_peers "" || true)"
[[ "$peers" == "10.0.0.1" ]] \
    || fail "two failed probes made a serving node vanish from the peer list: '$peers'"
(( $(elapsed) < window )) \
    || fail "live_peers waited $(elapsed)s instead of returning when the probe succeeded"
[[ "$(logged)" == *"re-probing it for up to ${window}s"* ]] \
    || fail "the retry was not announced to the operator: $(logged)"
[[ "$(logged)" == *"the earlier probe had failed"* ]] \
    || fail "the recovery was not reported, so the failed probes look like the truth: $(logged)"

# The address lookup fails the same transient way, and node_ip hides the
# error, so an empty address must not be a verdict either.
reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'none\nnone\n10.0.0.1\n' >"$plans/ip.node-1"
printf 'cluster\n' >"$plans/ca.10.0.0.1"
peers="$(drive live_peers "" || true)"
[[ "$peers" == "10.0.0.1" ]] \
    || fail "a transient 'az vm show' failure dropped a serving node: '$peers'"
grep -q '^ip node-1 none$' "$plans/probes.log" \
    || fail "the case did not actually exercise a failed address lookup"

# ===========================================================================
# A negative is still reachable, and still bounded
# ===========================================================================

reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'fail\n' >"$plans/ca.10.0.0.1"
peers="$(drive live_peers "" || true)"
[[ -z "$peers" ]] || fail "a node that never answers was returned as a peer: '$peers'"
(( $(elapsed) >= window )) \
    || fail "live_peers gave up after $(elapsed)s instead of re-probing for ${window}s"
(( $(elapsed) < window + 30 )) \
    || fail "live_peers re-probed for $(elapsed)s: the window is not bounded"
(( $(probes_for 10.0.0.1) > 1 )) \
    || fail "the node was asked once and written off: $(probes_for 10.0.0.1) probe(s)"

# Retrying must not soften what "serves the cluster CA" means. A node holding
# another CA answers every probe, and is still not a peer - that answer is
# evidence, and repeating the question does not change it.
reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'other\n' >"$plans/ca.10.0.0.1"
peers="$(drive live_peers "" || true)"
[[ -z "$peers" ]] \
    || fail "a node serving a different CA became a peer after a retry: '$peers'"
(( $(probes_for 10.0.0.1) > 1 )) || fail "the retry window was not spent on this node"

# ===========================================================================
# The peer list itself: order, exclusion, and a flaky node kept in it
# ===========================================================================

reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
groups_line node-2 10.0.0.2 2 join
printf 'cluster\n' >"$plans/ca.10.0.0.1"
printf 'fail\ncluster\n' >"$plans/ca.10.0.0.2"
peers="$(drive live_peers "" || true)"
[[ "$peers" == "10.0.0.1
10.0.0.2" ]] || fail "a flaky second node was dropped from the peer list: '$peers'"

reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
groups_line node-2 10.0.0.2 2 join
printf 'cluster\n' >"$plans/ca.10.0.0.1"
printf 'cluster\n' >"$plans/ca.10.0.0.2"
peers="$(drive live_peers node-2 || true)"
[[ "$peers" == "10.0.0.1" ]] \
    || fail "the excluded node is still in the peer list: '$peers'"
(( $(probes_for 10.0.0.2) == 0 )) || fail "the excluded node was probed anyway"

# ===========================================================================
# join_node: what the whole thing is for
# ===========================================================================

# The SUP-949 run, replayed: the first probe of a node that serves fails, and
# the bring-up has to continue through it.
reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'fail\ncluster\n' >"$plans/ca.10.0.0.1"
drive join_node '{}' 2 "" \
    || fail "join_node aborted on a single failed CA probe: $(logged)"
[[ "$(logged)" == *"joins through 10.0.0.1"* ]] \
    || fail "join_node did not seed the new node through the serving node: $(logged)"

# And when the cluster really serves nothing, it still stops - after the
# window, with an error that points at the probe and at the command that shows
# what each node answers, rather than at a cluster that may be fine.
reset_plans
groups_line node-1 10.0.0.1 1 bootstrap
printf 'fail\n' >"$plans/ca.10.0.0.1"
drive join_node '{}' 2 "" \
    && fail "join_node added a node to a cluster that serves no CA: $(logged)"
(( $(elapsed) >= window )) \
    || fail "join_node died after $(elapsed)s, before the re-probe window was out: $(logged)"
[[ "$(logged)" == *"each re-probed for ${window}s"* ]] \
    || fail "the fatal error does not say that every node was re-probed: $(logged)"
[[ "$(logged)" == *"cluster.sh status --cluster ca-test"* ]] \
    || fail "the fatal error does not say how to see what the nodes answer: $(logged)"

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
