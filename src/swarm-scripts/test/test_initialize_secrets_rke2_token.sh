#!/usr/bin/env bash

# The RKE2 cluster join token is generated here, once, on the swarm-init node,
# and read from SwarmSecrets by the swarm-cloud rke2 plugin (SUP-652). If this
# row is never written, the plugin postpones its apply forever and no cluster
# comes up — so the three cases that decide whether it gets written are worth a
# test: swarm-init mode writes it, any other mode does not, and a swarm that
# already has one keeps it.
#
# "Once" is also about what this script does NOT do: it reruns on every boot of
# the swarm-init node, and a rerun that mints a fresh token locks every future
# node out of a cluster that is otherwise healthy (SUP-700). The last cases
# check that an existing secret stops the generator from running at all. That
# the write itself also refuses to overwrite is pinned separately, against the
# real CLI, in test_swarm_cli_secrets.py — this test stubs the CLI out.

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

# Record every `openssl` call so a test can assert that a secret the swarm
# already holds is never even regenerated.
cat > "$test_root/stub/openssl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "openssl $*" >> "$SP_TEST_CALL_LOG"
exec /usr/bin/openssl "$@"
STUB
chmod +x "$test_root/stub/openssl"

# $1: vm mode written to the mode file, $2: ids SwarmDB already holds.
# Sets `log` to the path of the recorded swarm-cli call log.
#
# Deliberately not a function that echoes its result: bash suspends errexit
# inside the `$(...)` of an assignment, so a script under test that died
# half-way would read here as a script that simply wrote nothing. Returning
# through a variable keeps `set -e` live and the exit status checked.
run_script() {
    local vm_mode="$1" existing="${2:-}"
    local run_dir certs_dir call_log status
    run_dir="$(mktemp -d "$test_root/run.XXXXXXXX")"
    certs_dir="$run_dir/certs"
    call_log="$run_dir/calls.log"

    printf '%s\n' "$vm_mode" > "$test_root/etc/swarm/swarm-vm-mode"
    mkdir -p "$certs_dir"
    local key
    for key in "${CERT_SECRET_KEYS[@]}"; do
        printf -- '-----BEGIN TEST %s-----\n' "$key" > "$certs_dir/$key.pem"
    done
    # pki-cert-init leaves the swarm key here; the script stores it alongside
    # the rest of the PKI material (SUP-655) and fails the boot without it.
    printf 'test-swarm-key\n' > "$test_root/etc/swarm/swarm.key"
    : > "$call_log"

    status=0
    PATH="$test_root/stub:$PATH" \
    CONFIG="$test_root/sp/swarm/config.yaml" \
    VM_MODE_FILE="$test_root/etc/swarm/swarm-vm-mode" \
    SWARM_INIT_CERTS_DIR="$certs_dir" \
    SWARM_KEY_FILE="$test_root/etc/swarm/swarm.key" \
    SP_TEST_CALL_LOG="$call_log" \
    SP_TEST_EXISTING_SECRETS="$existing" \
        bash "$under_test" >/dev/null || status=$?
    [[ "$status" -eq 0 ]] || fail "00-initialize-secrets.sh exited $status in vm mode '$vm_mode'"

    log="$call_log"
}

created_token() {
    sed -n 's/^create SwarmSecrets rke2_join_token --value //p' "$1"
}

# 1. swarm-init mode generates the token, and generates it as a single-line,
#    64-character hex string — the plugin writes it into YAML unquoted.
run_script init
token="$(created_token "$log")"
[[ -n "$token" ]] || fail "swarm-init mode did not create the rke2_join_token secret"
[[ "$(created_token "$log" | wc -l)" -eq 1 ]] || fail "rke2_join_token was created more than once"
[[ "$token" =~ ^[0-9a-f]{64}$ ]] || fail "rke2_join_token is not 32 random bytes of hex: '$token'"

# ... and a second swarm-init node does not reuse the first one's value.
run_script init
second="$(created_token "$log")"
[[ "$second" != "$token" ]] || fail "rke2_join_token is not random: two runs produced '$token'"

# 2. Any other vm mode leaves the token alone: a joining node reads the
#    replicated row instead of racing the init node with a second value.
run_script join
[[ -z "$(created_token "$log")" ]] || fail "non-init mode created an rke2_join_token secret"
grep -q 'create SwarmSecrets base_domain' "$log" || fail "non-init mode skipped the plain secrets too"

# 3. A swarm that already holds the token keeps it — reruns must not rotate a
#    live cluster's join token out from under it. The cluster's etcd bootstrap
#    data is sealed with the original, so a rotated row leaves the running
#    nodes healthy and rejects every node that joins afterwards (SUP-700).
run_script init rke2_join_token
[[ -z "$(created_token "$log")" ]] || fail "an existing rke2_join_token secret was overwritten"
grep -q 'get SwarmSecrets rke2_join_token' "$log" || fail "the existing secret was never looked up"
! grep -q 'openssl rand -hex 32' "$log" || fail "a token was generated although the swarm already holds one"

# 4. The same holds for the other secret this script mints from scratch: the
#    PKI auth token is what the authority accepts certificate requests with.
run_script init "rke2_join_token pki_auth_token"
! grep -q 'create SwarmSecrets pki_auth_token' "$log" || fail "an existing pki_auth_token secret was overwritten"
! grep -q 'openssl rand -base64 64' "$log" || fail "a pki_auth_token was generated although the swarm already holds one"

# ... and when it is absent it is still minted, so the guard cannot pass by
#     simply never generating anything.
run_script init
grep -q 'create SwarmSecrets pki_auth_token' "$log" || fail "a swarm without a pki_auth_token did not get one"

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
