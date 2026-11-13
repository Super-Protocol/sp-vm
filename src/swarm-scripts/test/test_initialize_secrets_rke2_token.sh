#!/usr/bin/env bash

# The RKE2 cluster join token is generated here, once, on the swarm-init node,
# and read from SwarmSecrets by the swarm-cloud rke2 plugin (SUP-652). If this
# row is never written, the plugin postpones its apply forever and no cluster
# comes up — so the three cases that decide whether it gets written are worth a
# test: swarm-init mode writes it, any other mode does not, and a swarm that
# already has one keeps it.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
under_test="$script_dir/../00-initialize-secrets.sh"
[[ -r "$under_test" ]] || { echo "FAIL: not found: $under_test" >&2; exit 1; }

test_root="$(mktemp -d -t sp-initialize-secrets.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

CERT_SECRET_KEYS=(
    root_basic_cert root_basic_key
    root_lite_cert root_lite_key
    subroot_device_basic_cert subroot_device_basic_key
    subroot_device_lite_cert subroot_device_lite_key
    subroot_evidence_basic_cert subroot_evidence_basic_key
    subroot_evidence_lite_cert subroot_evidence_lite_key
)

mkdir -p "$test_root/sp/swarm" "$test_root/etc/swarm" "$test_root/stub"
cat > "$test_root/sp/swarm/config.yaml" <<'YAML'
base_domain: example.test
swarm_domain: swarm.example.test
pki_domain: pki.example.test
gateway_hostname: gw.example.test
global_id: g1
powerdns_api_url: http://127.0.0.1:8081
powerdns_api_key: pdns-key
YAML

# Stand in for `python3`: `python3 -c ...` is the script's YAML reader and has to
# keep working, while `python3 .../swarm-cli.py ...` is the SwarmDB write we want
# to observe. SP_TEST_EXISTING_SECRETS lists the ids SwarmDB already holds.
cat > "$test_root/stub/python3" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-c" ]]; then
    exec /usr/bin/python3 "$@"
fi
case "${1:-}" in
    *swarm-cli.py)
        shift
        echo "$*" >> "$SP_TEST_CALL_LOG"
        if [[ "${1:-}" == "get" ]]; then
            for existing in ${SP_TEST_EXISTING_SECRETS:-}; do
                [[ "${3:-}" == "$existing" ]] && exit 0
            done
            exit 1
        fi
        exit 0
        ;;
esac
exec /usr/bin/python3 "$@"
STUB
chmod +x "$test_root/stub/python3"

# $1: vm mode written to the mode file, $2: ids SwarmDB already holds.
# Echoes the path of the recorded swarm-cli call log.
run_script() {
    local vm_mode="$1" existing="${2:-}"
    local run_dir certs_dir call_log
    run_dir="$(mktemp -d "$test_root/run.XXXXXXXX")"
    certs_dir="$run_dir/certs"
    call_log="$run_dir/calls.log"

    printf '%s\n' "$vm_mode" > "$test_root/etc/swarm/swarm-vm-mode"
    mkdir -p "$certs_dir"
    local key
    for key in "${CERT_SECRET_KEYS[@]}"; do
        printf -- '-----BEGIN TEST %s-----\n' "$key" > "$certs_dir/$key.pem"
    done
    : > "$call_log"

    PATH="$test_root/stub:$PATH" \
    CONFIG="$test_root/sp/swarm/config.yaml" \
    VM_MODE_FILE="$test_root/etc/swarm/swarm-vm-mode" \
    SWARM_INIT_CERTS_DIR="$certs_dir" \
    SP_TEST_CALL_LOG="$call_log" \
    SP_TEST_EXISTING_SECRETS="$existing" \
        bash "$under_test" >/dev/null

    printf '%s\n' "$call_log"
}

created_token() {
    sed -n 's/^create SwarmSecrets rke2_join_token --value //p' "$1"
}

# 1. swarm-init mode generates the token, and generates it as a single-line,
#    64-character hex string — the plugin writes it into YAML unquoted.
log="$(run_script init)"
token="$(created_token "$log")"
[[ -n "$token" ]] || fail "swarm-init mode did not create the rke2_join_token secret"
[[ "$(created_token "$log" | wc -l)" -eq 1 ]] || fail "rke2_join_token was created more than once"
[[ "$token" =~ ^[0-9a-f]{64}$ ]] || fail "rke2_join_token is not 32 random bytes of hex: '$token'"

# ... and a second swarm-init node does not reuse the first one's value.
second="$(created_token "$(run_script init)")"
[[ "$second" != "$token" ]] || fail "rke2_join_token is not random: two runs produced '$token'"

# 2. Any other vm mode leaves the token alone: a joining node reads the
#    replicated row instead of racing the init node with a second value.
log="$(run_script join)"
[[ -z "$(created_token "$log")" ]] || fail "non-init mode created an rke2_join_token secret"
grep -q 'create SwarmSecrets base_domain' "$log" || fail "non-init mode skipped the plain secrets too"

# 3. A swarm that already holds the token keeps it — reruns must not rotate a
#    live cluster's join token out from under it.
log="$(run_script init rke2_join_token)"
[[ -z "$(created_token "$log")" ]] || fail "an existing rke2_join_token secret was overwritten"
grep -q 'get SwarmSecrets rke2_join_token' "$log" || fail "the existing secret was never looked up"

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
