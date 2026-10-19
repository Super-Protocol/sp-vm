#!/usr/bin/env bash

# SUP-376: the /run/sp-health publishing convention, and the two publishers this
# issue adds.
#
# What is being guarded here is not "the scripts run". It is the three
# properties that make the surface load-bearing, each of which has a named
# failure behind it:
#
#   - `serving` is reachable ONLY from positive local evidence. Every other
#     publisher reports a gate, and no combination of gates means the node
#     serves: SUP-308/331 was a departed node whose gates all stayed ok;
#   - the record carries NO names, IPs or member list. It is serialised to
#     :9180, which hardening-vm.sh opens with no source restriction, over plain
#     HTTP with no auth;
#   - the health surface does not sit behind the thing it reports on. The GPU
#     barrier exits 1 and never retries, so Requires= on it meant no :9180 at
#     all on a GPU node whose GPU never came ready.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_HEALTH_TEST_INSTALLED_ROOT:-}" ]]; then
    config_dir="$SP_HEALTH_TEST_INSTALLED_ROOT"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/etc/systemd/system"
    pki_unit_dir="$config_dir/etc/systemd/system"
else
    config_dir="$repository_root/src/rootfs/files/configs"
    bin_dir="$config_dir/usr/local/bin"
    unit_dir="$config_dir/etc/systemd/system"
    pki_unit_dir="$config_dir/pki-service/systemd"
fi

publish="$bin_dir/sp-health-publish"
probe="$bin_dir/sp-node-serving-probe"
gpu_ready="$bin_dir/sp-nvidia-gpu-ready"
serving_service="$unit_dir/sp-node-serving.service"
serving_timer="$unit_dir/sp-node-serving.timer"

test_root="$(mktemp -d -t sp-health-publishers.XXXXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

json_field() {
    sed -n "s/^[[:space:]]*\"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$1" | tail -n1
}

unit_value() {
    sed -n "s/^$2=//p" "$1" | tail -n1
}

for required in "$publish" "$probe" "$gpu_ready"; do
    [[ -x "$required" ]] || fail "$required is missing or not executable"
done
for required in "$serving_service" "$serving_timer"; do
    [[ -f "$required" ]] || fail "$required is missing"
done

# ===========================================================================
# sp-health-publish: the single writer of the record format
# ===========================================================================

pub_dir="$test_root/publish"
mkdir -p "$pub_dir"

run_publish() {
    SP_HEALTH_STATE_DIR="$pub_dir" "$publish" "$@" 2>"$pub_dir/stderr"
}

run_publish --unit node-serving.service --state ok --reason-class serving \
    --reason "this node serves" --ttl-sec 60 --bool ca_ok=true --bool membership_ok=true \
    || fail "a valid record was rejected: $(cat "$pub_dir/stderr")"
record="$pub_dir/node-serving.json"
[[ -f "$record" ]] || fail "the record was not written to the directory the endpoint reads"
[[ "$(json_field "$record" schema)" == "sp.unit-health/v1" ]] \
    || fail "the record does not name its schema"
for field in unit state terminal gate ttl_sec reason_class reason updated_at; do
    grep -q "\"$field\":" "$record" || fail "the record is missing the $field field"
done
[[ "$(json_field "$record" terminal)" == "false" ]] || fail "terminal did not default to false"
[[ "$(json_field "$record" gate)" == "true" ]] || fail "gate did not default to true"
grep -q '"ca_ok": true,' "$record" || fail "a --bool flag did not reach the record as a boolean"
grep -q '"exit_code": null,' "$record" || fail "an absent exit code is not null"

# updated_at must be the UTC instant a reader compares against ttl_sec. A local
# timestamp, or one without the Z, makes every record look stale or fresh by
# the guest's timezone.
grep -qE '"updated_at": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$record" \
    || fail "updated_at is not an RFC3339 UTC instant: $(json_field "$record" updated_at)"

# The write must be atomic: the endpoint reads this directory on a short timer,
# and a reader that catches a half-written file would see the node as unknown.
! ls "$pub_dir" | grep -q '\.tmp$' || fail "a .tmp file was left behind by the publish"

# Validation, not trust. A typo in a caller must not reach an unauthenticated
# port as an unparseable state, a negative ttl, or an injected field.
run_publish --unit node-serving.service --state booting --reason-class x \
    --reason y --ttl-sec 60 && fail "an unknown state was accepted"
run_publish --unit node-serving.service --state ok --reason-class x \
    --reason y --ttl-sec 0 && fail "a zero ttl was accepted: the record would never go stale"
run_publish --unit node-serving.service --state ok --reason-class x \
    --reason y --ttl-sec -5 && fail "a negative ttl was accepted"
run_publish --unit node-serving.service --state ok --reason-class 'Not A Class' \
    --reason y --ttl-sec 60 && fail "a non-kebab-case reason class was accepted"
run_publish --unit 'node-serving' --state ok --reason-class x \
    --reason y --ttl-sec 60 && fail "a value that is not a unit name was accepted as --unit"
run_publish --unit node-serving.service --state ok --reason-class x \
    --reason "" --ttl-sec 60 && fail "a state with no reason was accepted"
run_publish --unit node-serving.service --state ok --reason-class x \
    --reason y --ttl-sec 60 --bool 'ca_ok=maybe' && fail "a non-boolean --bool value was accepted"
# A --bool that collides with a record field emits a DUPLICATE JSON key, and a
# duplicate key is not an error to a parser - the last one wins. So this would
# have produced {state: "ok", ..., terminal: true}: exactly the record the
# --terminal rule below exists to make unconstructible, arriving at the
# endpoint looking like a legitimate terminal verdict.
for reserved in schema unit state terminal gate ttl_sec exit_code reason_class reason updated_at; do
    run_publish --unit node-serving.service --state ok --reason-class x --reason y \
        --ttl-sec 60 --bool "$reserved=true" \
        && fail "--bool $reserved was accepted: it would override the record's own $reserved"
done
# Same defect between two --bool flags.
run_publish --unit node-serving.service --state ok --reason-class x --reason y \
    --ttl-sec 60 --bool ca_ok=true --bool ca_ok=false \
    && fail "a duplicate --bool key was accepted: the second would override the first"
# And the legitimate shape is untouched by the new rule.
run_publish --unit node-serving.service --state ok --reason-class serving --reason y \
    --ttl-sec 60 --bool ca_ok=true --bool membership_ok=false \
    || fail "the new --bool rules rejected a legitimate pair of flags"
[[ "$(json_field "$record" state)" == "ok" ]] || fail "the legitimate pair did not publish"
grep -q '"membership_ok": false,' "$record" || fail "the second legitimate --bool was lost"
run_publish --unit node-serving.service --state ok --reason-class x \
    --reason y --ttl-sec 60 --terminal true \
    && fail "terminal was accepted on a state that is not failed"
# A record name is a file name, never a path: the endpoint's directory is
# compiled in, and nothing a publisher passes may walk out of it.
run_publish --unit node-serving.service --state ok --reason-class x --reason y \
    --ttl-sec 60 --record '../escaped' && fail "a path traversal was accepted as --record"
[[ ! -e "$test_root/escaped.json" ]] || fail "a publish escaped the state directory"

# The format is JSON built without a JSON library and is parsed on an
# unauthenticated port: no field may break out of its string, whatever a caller
# passes. A quote, a backslash or a newline must change the record's CONTENT
# and never its SHAPE.
clean_lines="$(wc -l <"$record")"
run_publish --unit node-serving.service --state failed --reason-class quoting \
    --reason 'a "quoted" value and a \backslash and
a newline' --ttl-sec 60 --terminal true --bool ca_ok=false --bool membership_ok=false \
    || fail "a reason with quoting was rejected rather than sanitized"
! grep -q '"reason": "a "quoted"' "$record" || fail "a quote broke out of the reason string"
! grep -q '\\' "$record" || fail "a backslash reached the record and could escape the closing quote"
[[ "$(wc -l <"$record")" == "$clean_lines" ]] \
    || fail "a newline in a reason changed the record from $clean_lines lines to $(wc -l <"$record")"
# A real parser where one is available. The rootfs build stage is a minimal
# ubuntu:noble with no python3, so this is a bonus check on a developer machine
# and in CI rather than the load-bearing assertion - the shape assertions above
# are what run everywhere.
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$record" 2>/dev/null \
        || fail "the record is not parseable JSON after a hostile reason: $(cat "$record")"
fi

# ===========================================================================
# node-serving: the only positive witness, and it names nothing
# ===========================================================================

make_probe_env() {
    local case_dir="$1" ca_mode="$2" members_mode="$3"
    mkdir -p "$case_dir/state" "$case_dir/run"
    cat >"$case_dir/swarm-db-config.yaml" <<'YAML'
memberlist:
  advertise_addr: 203.0.113.17
  join_addresses:
  - 10.77.0.5:7946
node:
  data_dir: /var/lib/swarm-db
  host: 0.0.0.0
  name: sp-cloud-node-2-ab12
  port: 8001
YAML
    # Stands in for curl. argv carries the URL, so the probe is also proved to
    # call the two endpoints the host calls and no others.
    cat >"$case_dir/fake-curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
printf '%s\n' "$url" >>"$SP_TEST_CURL_LOG"
case "$url" in
    *9443*)
        case "$SP_TEST_CA_MODE" in
            pem) printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n'; exit 0 ;;
            # :9443 answers before it has a CA to serve - the exact shape that
            # makes "the port is open" the wrong probe.
            empty) exit 0 ;;
            *) exit 7 ;;
        esac
        ;;
    *4001*)
        case "$SP_TEST_MEMBERS_MODE" in
            present) printf '[{"node_id":"sp-cloud-node-2-ab12","status":"active"},{"node_id":"sp-cloud-node-1-cd34","status":"active"}]'; exit 0 ;;
            spaced) printf '[{"node_id": "sp-cloud-node-2-ab12", "status": "active"}]'; exit 0 ;;
            # The node answers its own API but gossip does not list it: SUP-366,
            # node Ready is not node serving.
            absent) printf '[{"node_id":"sp-cloud-node-1-cd34","status":"active"}]'; exit 0 ;;
            # A substring of this node's name must not count as this node.
            prefix) printf '[{"node_id":"sp-cloud-node-2-ab12-replica","status":"active"}]'; exit 0 ;;
            *) exit 7 ;;
        esac
        ;;
esac
exit 7
EOF
    chmod +x "$case_dir/fake-curl"
    : >"$case_dir/curl.log"
    printf '%s' "$ca_mode" >"$case_dir/ca-mode"
    printf '%s' "$members_mode" >"$case_dir/members-mode"
}

run_probe() {
    local case_dir="$1" budget="${2:-1800}"
    SP_HEALTH_PUBLISH="$publish" \
    SP_HEALTH_STATE_DIR="$case_dir/state" \
    SP_NODE_SERVING_RUNTIME_DIR="$case_dir/run" \
    SP_CURL="$case_dir/fake-curl" \
    SP_NODE_SERVING_SWARM_DB_CONFIG="$case_dir/swarm-db-config.yaml" \
    SP_NODE_SERVING_BUDGET="$budget" \
    SP_TEST_CURL_LOG="$case_dir/curl.log" \
    SP_TEST_CA_MODE="$(cat "$case_dir/ca-mode")" \
    SP_TEST_MEMBERS_MODE="$(cat "$case_dir/members-mode")" \
        "$probe" >"$case_dir/stdout" 2>"$case_dir/stderr"
}

# --- both probes pass: the one and only source of `serving` ----------------
ok_dir="$test_root/serving"
make_probe_env "$ok_dir" pem present
run_probe "$ok_dir" || fail "a serving node's probe exited non-zero"
serving_record="$ok_dir/state/node-serving.json"
[[ "$(json_field "$serving_record" state)" == "ok" ]] \
    || fail "a serving node did not publish ok: $(cat "$serving_record")"
[[ "$(json_field "$serving_record" reason_class)" == "serving" ]] \
    || fail "a serving node did not publish the serving class"
grep -q '"ca_ok": true,' "$serving_record" || fail "ca_ok is not true on a serving node"
grep -q '"membership_ok": true,' "$serving_record" || fail "membership_ok is not true on a serving node"

# It must probe exactly what the host probes, from loopback.
grep -q 'https://127.0.0.1:9443/api/v1/pki/certs/ca' "$ok_dir/curl.log" \
    || fail "the probe does not make fetch_ca's call"
grep -q 'http://127.0.0.1:4001/nodes' "$ok_dir/curl.log" \
    || fail "the probe does not read the local node API's membership"
[[ "$(wc -l <"$ok_dir/curl.log")" == "2" ]] \
    || fail "the probe made $(wc -l <"$ok_dir/curl.log") calls, not the two it is specified to make"

# --- and it publishes two booleans and one status word, nothing else -------
# The record leaves the guest unauthenticated. Every value in the fixture that
# is a name, an address or another node must be absent from it.
for secret in sp-cloud-node-2-ab12 sp-cloud-node-1-cd34 203.0.113.17 10.77.0.5 127.0.0.1 9443 4001; do
    ! grep -qF "$secret" "$serving_record" \
        || fail "the record carries '$secret': names, IPs, ports and the member list must never reach the surface"
done
# Positive form of the same rule, so a future field cannot slip past the list
# above: every key in the record is on the allowlist.
while IFS= read -r key; do
    case "$key" in
        schema|unit|state|terminal|gate|ttl_sec|exit_code|reason_class|reason|updated_at) ;;
        ca_ok|membership_ok) ;;
        *) fail "the record carries an unexpected field '$key'" ;;
    esac
done < <(sed -n 's/^[[:space:]]*"\([a-z_]*\)":.*/\1/p' "$serving_record")

# --- neither half alone is evidence of serving -----------------------------
# A CA with no membership is SUP-366 (node Ready is not node serving); a
# membership entry with no CA is a node that gossips but cannot serve a request.
for pair in "pem:absent:membership-absent" "empty:present:ca-unavailable" "down:present:ca-unavailable" "down:absent:no-local-evidence" "pem:prefix:membership-absent"; do
    IFS=: read -r ca members expected_class <<<"$pair"
    half_dir="$test_root/half-$ca-$members"
    make_probe_env "$half_dir" "$ca" "$members"
    run_probe "$half_dir" || fail "the $ca/$members probe exited non-zero"
    half_record="$half_dir/state/node-serving.json"
    [[ "$(json_field "$half_record" state)" != "ok" ]] \
        || fail "$ca/$members published ok: serving requires BOTH halves"
    [[ "$(json_field "$half_record" reason_class)" == "$expected_class" ]] \
        || fail "$ca/$members was classified '$(json_field "$half_record" reason_class)', expected $expected_class"
done

# A member whose name merely CONTAINS this node's name is a different node.
prefix_record="$test_root/half-pem-prefix/state/node-serving.json"
grep -q '"membership_ok": false,' "$prefix_record" \
    || fail "a node whose name is a prefix of a member's was counted as present"

# Whitespace in the payload must not decide the verdict.
spaced_dir="$test_root/spaced"
make_probe_env "$spaced_dir" pem spaced
run_probe "$spaced_dir" || fail "the spaced-payload probe exited non-zero"
[[ "$(json_field "$spaced_dir/state/node-serving.json" state)" == "ok" ]] \
    || fail "a non-compact /nodes payload was read as absent membership"

# --- the budget: `attempting` until it runs out, then `failed` -------------
# Both are non-terminal. This unit is a witness, not an authority on
# impossibility: a node can start serving at any later point, and the verdicts
# that end a wait come from gates that know they cannot be retried.
budget_dir="$test_root/budget"
make_probe_env "$budget_dir" down absent
run_probe "$budget_dir" 1800 || fail "the in-budget probe exited non-zero"
budget_record="$budget_dir/state/node-serving.json"
[[ "$(json_field "$budget_record" state)" == "attempting" ]] \
    || fail "a node inside its bring-up budget was not reported as attempting"
[[ "$(json_field "$budget_record" terminal)" == "false" ]] \
    || fail "node-serving published a terminal verdict; only a gate may do that"

# Rewind the first-run marker past the budget rather than waiting for it.
printf '%s\n' "$(( $(date -u '+%s') - 2000 ))" >"$budget_dir/run/first-run"
run_probe "$budget_dir" 1800 || fail "the past-budget probe exited non-zero"
[[ "$(json_field "$budget_record" state)" == "failed" ]] \
    || fail "a node past its bring-up budget was still reported as attempting - the SUP-370 shape"
[[ "$(json_field "$budget_record" terminal)" == "false" ]] \
    || fail "an exhausted budget was published as terminal"

# --- the sentinel is the only thing that makes the budget advance -----------
# Every case above starts from a well-formed sentinel, which is exactly how a
# zero-budget bug hides: testing the sentinel's EXISTENCE rather than its
# CONTENT left first_run at `now` on every run, so elapsed was 0 for the life
# of the boot and `failed` was unreachable. The record stayed `attempting`, was
# rewritten every 30s and so never went stale either - the endpoint cannot
# catch this one, and the rollup reads `booting` forever. SUP-370's
# never-clearing condition, reproduced by the code meant to report it.
#
# A truncated sentinel is not hypothetical: the probe's own write truncates
# before it writes, so a kill or a full tmpfs in between leaves exactly this.
for broken in '' $'\n' 'not-a-number' '12x34'; do
    sentinel_dir="$test_root/sentinel-$(printf '%s' "${broken:-empty}" | tr -cd '[:alnum:]')x"
    make_probe_env "$sentinel_dir" down absent
    printf '%s' "$broken" >"$sentinel_dir/run/first-run"
    run_probe "$sentinel_dir" 1 || fail "the broken-sentinel probe exited non-zero"
    repaired="$(cat "$sentinel_dir/run/first-run")"
    [[ "$repaired" =~ ^[0-9]+$ ]] \
        || fail "an unusable sentinel was not rewritten, so the budget can never advance: '[$repaired]'"
    # And with a usable sentinel in place, the budget actually fires.
    printf '%s\n' "$(( $(date -u '+%s') - 100 ))" >"$sentinel_dir/run/first-run"
    run_probe "$sentinel_dir" 1 || fail "the repaired-sentinel probe exited non-zero"
    [[ "$(json_field "$sentinel_dir/state/node-serving.json" state)" == "failed" ]] \
        || fail "the budget did not fire after the sentinel was repaired"
done

# A sentinel AHEAD of now cannot be a first-run time, and chrony steps the
# clock during boot - so this is ordinary, not corruption. Restarting the
# budget is right; freezing it at zero is not.
future_dir="$test_root/sentinel-future"
make_probe_env "$future_dir" down absent
printf '%s\n' "$(( $(date -u '+%s') + 99999 ))" >"$future_dir/run/first-run"
run_probe "$future_dir" 1800 || fail "the future-sentinel probe exited non-zero"
(( $(cat "$future_dir/run/first-run") <= $(date -u '+%s') )) \
    || fail "a sentinel in the future was kept, so the budget would never advance"

# --- /run/sp-health holds RECORDS ONLY -------------------------------------
# The endpoint enumerates this directory on an unauthenticated port, so every
# non-record file in it is one filter bug away from being served. The probe's
# budget sentinel lives in its own /run directory for that reason.
while IFS= read -r stray; do
    case "$(basename "$stray")" in
        *.json) ;;
        *) fail "the records directory holds a non-record file: $(basename "$stray")" ;;
    esac
done < <(find "$budget_dir/state" -type f)
[[ -f "$budget_dir/run/first-run" ]] \
    || fail "the budget sentinel is not in the publisher's own per-boot runtime directory"

# And it recovers: the record is a witness, not a latch.
printf '%s' pem >"$budget_dir/ca-mode"
printf '%s' present >"$budget_dir/members-mode"
run_probe "$budget_dir" 1800 || fail "the recovering probe exited non-zero"
[[ "$(json_field "$budget_record" state)" == "ok" ]] \
    || fail "a node that started serving stayed failed"

# The budget is measured from the first run SINCE BOOT, and /run is tmpfs - so
# the marker must live under /run and nowhere persistent. Asserted on the
# script's own default rather than on the test's override.
grep -q 'SP_NODE_SERVING_RUNTIME_DIR:-/run/' "$probe" \
    || fail "the budget sentinel's default location is not under /run, so it could outlive its boot"

# --- ttl_sec is twice the TIMER INTERVAL, not twice an attempt -------------
# For a repeating publisher the ttl bounds the gap between writes. Get this
# wrong and a healthy node reads as stale on every other poll.
timer_interval="$(unit_value "$serving_timer" OnUnitActiveSec)"
[[ "$timer_interval" =~ ^([0-9]+)s$ ]] \
    || fail "the timer interval is not a plain number of seconds: '${timer_interval:-<unset>}'"
interval_sec="${BASH_REMATCH[1]}"
record_ttl="$(json_field "$serving_record" ttl_sec)"
[[ "$record_ttl" =~ ^[0-9]+$ ]] || fail "node-serving published a non-numeric ttl_sec"
(( record_ttl == interval_sec * 2 )) \
    || fail "ttl_sec ${record_ttl} is not twice the ${interval_sec}s timer interval"
service_timeout="$(unit_value "$serving_service" TimeoutStartSec)"
[[ "$service_timeout" =~ ^[0-9]+$ ]] \
    || fail "the probe service has no bounded TimeoutStartSec"
(( service_timeout < record_ttl )) \
    || fail "a probe may run for ${service_timeout}s but the record expires after ${record_ttl}s: a serving node would read as stale"

# The probe must not depend on the thing it reports on.
! grep -qE '^(Requires|Wants|BindsTo)=.*swarm-node\.service' "$serving_service" \
    || fail "the probe depends on swarm-node, so it goes silent exactly when it has something to say"
grep -qE '^After=.*swarm-node\.service' "$serving_service" \
    || fail "the probe is not ordered after swarm-node"
grep -q '^WantedBy=timers.target$' "$serving_timer" \
    || fail "the timer is not installed into timers.target"

# ===========================================================================
# the GPU barrier is a publisher, and the health surface is not behind it
# ===========================================================================

make_gpu_env() {
    local case_dir="$1"
    mkdir -p "$case_dir/state" "$case_dir/run"
    cat >"$case_dir/gpu-present" <<'EOF'
#!/bin/bash
[[ -n "${SP_TEST_GPU_PRESENT:-}" ]]
EOF
    cat >"$case_dir/fabric-condition" <<'EOF'
#!/bin/bash
[[ -n "${SP_TEST_FABRIC_REQUIRED:-}" ]]
EOF
    cat >"$case_dir/systemctl" <<'EOF'
#!/bin/bash
# is-active <unit>: the test decides per unit via SP_TEST_ACTIVE.
if [[ "$1" == "is-active" ]]; then
    unit="${@: -1}"
    [[ ",${SP_TEST_ACTIVE:-}," == *",${unit},"* ]]
    exit $?
fi
exit 0
EOF
    chmod +x "$case_dir/gpu-present" "$case_dir/fabric-condition" "$case_dir/systemctl"
}

run_gpu_ready() {
    local case_dir="$1"
    SP_HEALTH_PUBLISH="$publish" \
    SP_HEALTH_STATE_DIR="$case_dir/state" \
    SP_NVIDIA_GPU_PRESENT="$case_dir/gpu-present" \
    SP_NVIDIA_FABRIC_CONDITION="$case_dir/fabric-condition" \
    SP_SYSTEMCTL="$case_dir/systemctl" \
    SP_NVIDIA_READY_FILE="$case_dir/run/cc-ready" \
    SP_NVIDIA_READY_TIMEOUT="${SP_TEST_READY_TIMEOUT:-1}" \
    SP_NVIDIA_PERSISTENCE_MAX_ATTEMPTS="${SP_TEST_MAX_PERSISTENCE:-2}" \
    SP_SLEEP=/bin/true \
        "$gpu_ready" >"$case_dir/stdout" 2>"$case_dir/stderr"
}

# --- a CPU-only VM says so, rather than saying nothing ---------------------
nogpu_dir="$test_root/gpu-absent"
make_gpu_env "$nogpu_dir"
run_gpu_ready "$nogpu_dir" || fail "the CPU-only barrier did not exit 0"
nogpu_record="$nogpu_dir/state/sp-nvidia-gpu-ready.json"
[[ "$(json_field "$nogpu_record" state)" == "ok" ]] \
    || fail "a CPU-only VM did not publish ok: 'no GPU to wait for' and 'still waiting' are different facts"
[[ "$(json_field "$nogpu_record" reason_class)" == "no-gpu" ]] \
    || fail "a CPU-only VM published '$(json_field "$nogpu_record" reason_class)'"

# --- a GPU that comes ready ------------------------------------------------
ready_dir="$test_root/gpu-ready"
make_gpu_env "$ready_dir"
touch "$ready_dir/run/cc-ready"
SP_TEST_GPU_PRESENT=1 SP_TEST_ACTIVE=nvidia-persistenced.service \
    run_gpu_ready "$ready_dir" || fail "a ready GPU did not satisfy the barrier"
ready_record="$ready_dir/state/sp-nvidia-gpu-ready.json"
[[ "$(json_field "$ready_record" state)" == "ok" ]] \
    || fail "a ready GPU did not publish ok: $(cat "$ready_record")"
[[ "$(json_field "$ready_record" reason_class)" == "gpu-ready" ]] \
    || fail "a ready GPU published '$(json_field "$ready_record" reason_class)'"

# --- the Fabric Manager timeout: the H200 failure this was filed for -------
# Type=oneshot with no Restart=, so systemd will never run this again, and
# without the barrier pki-cert-init and pki-authority-sync never start. There is
# nothing left to wait for, which is precisely what terminal: true means.
fm_dir="$test_root/gpu-fabricmanager-timeout"
make_gpu_env "$fm_dir"
SP_TEST_GPU_PRESENT=1 SP_TEST_FABRIC_REQUIRED=1 SP_TEST_ACTIVE= \
    run_gpu_ready "$fm_dir" && fail "a Fabric Manager timeout exited 0"
fm_record="$fm_dir/state/sp-nvidia-gpu-ready.json"
[[ "$(json_field "$fm_record" state)" == "failed" ]] \
    || fail "a Fabric Manager timeout published no failure: $(cat "$fm_record" 2>/dev/null)"
[[ "$(json_field "$fm_record" terminal)" == "true" ]] \
    || fail "a Fabric Manager timeout was not terminal, so a host would keep waiting on a unit systemd will never retry"
[[ "$(json_field "$fm_record" reason_class)" == "fabricmanager-timeout" ]] \
    || fail "the Fabric Manager timeout lost its class"
[[ "$(json_field "$fm_record" gate)" == "true" ]] \
    || fail "the GPU barrier did not publish itself as a gate; the rollup would ignore it"

# --- nvidia-persistenced exhausting its attempts ---------------------------
pd_dir="$test_root/gpu-persistenced-failed"
make_gpu_env "$pd_dir"
SP_TEST_GPU_PRESENT=1 SP_TEST_ACTIVE= \
    run_gpu_ready "$pd_dir" && fail "an exhausted persistenced retry exited 0"
pd_record="$pd_dir/state/sp-nvidia-gpu-ready.json"
[[ "$(json_field "$pd_record" state)" == "failed" ]] \
    || fail "an exhausted persistenced retry published no failure"
[[ "$(json_field "$pd_record" terminal)" == "true" ]] \
    || fail "an exhausted persistenced retry was not terminal"
[[ "$(json_field "$pd_record" reason_class)" == "persistenced-failed" ]] \
    || fail "the persistenced failure lost its class"

# --- the barrier publishes while it waits, and the ttl covers the wait -----
# The record has to exist DURING bring-up, or a host polling a GPU node sees
# nothing for 20 minutes and cannot tell it from a node that is gone.
gpu_ttl="$(json_field "$fm_record" ttl_sec)"
[[ "$gpu_ttl" =~ ^[0-9]+$ ]] || fail "the barrier published a non-numeric ttl_sec"
default_wait="$(sed -n 's/^readonly wait_timeout="\${SP_NVIDIA_READY_TIMEOUT:-\([0-9]*\)}".*/\1/p' "$gpu_ready")"
[[ "$default_wait" =~ ^[0-9]+$ ]] || fail "could not read the barrier's default wait timeout"
waiting_dir="$test_root/gpu-waiting"
make_gpu_env "$waiting_dir"
SP_TEST_GPU_PRESENT=1 SP_TEST_FABRIC_REQUIRED=1 SP_TEST_ACTIVE= SP_TEST_READY_TIMEOUT=1 \
    run_gpu_ready "$waiting_dir" && true
waiting_record="$waiting_dir/state/sp-nvidia-gpu-ready.json"
grep -q 'waiting-for-gpu\|fabricmanager-timeout' "$waiting_record" \
    || fail "the barrier published nothing while it was waiting"
# With the default timeout the ttl must outlast the whole wait, or a node
# legitimately 15 minutes into GPU bring-up reads as stale.
SP_NVIDIA_READY_TIMEOUT="$default_wait" SP_HEALTH_PUBLISH="$publish" \
    SP_HEALTH_STATE_DIR="$waiting_dir/state" \
    SP_NVIDIA_GPU_PRESENT="$waiting_dir/gpu-present" \
    SP_NVIDIA_FABRIC_CONDITION="$waiting_dir/fabric-condition" \
    SP_SYSTEMCTL="$waiting_dir/systemctl" \
    SP_NVIDIA_READY_FILE="$waiting_dir/run/cc-ready" \
    SP_SLEEP=/bin/true SP_TEST_GPU_PRESENT=1 SP_TEST_ACTIVE=x \
    timeout 10 "$gpu_ready" >/dev/null 2>&1 || true
default_ttl="$(json_field "$waiting_record" ttl_sec)"
(( default_ttl > default_wait )) \
    || fail "ttl_sec ${default_ttl} does not outlast the ${default_wait}s wait it covers"

# --- and the surface it all reports to is not behind the barrier -----------
measurements_unit="$pki_unit_dir/pki-vm-measurements.service"
[[ -f "$measurements_unit" ]] || fail "pki-vm-measurements.service is missing from $pki_unit_dir"
! grep -qE '^(Requires|Wants|BindsTo|After)=.*sp-nvidia-gpu-ready\.service' "$measurements_unit" \
    || fail ":9180 is behind the GPU barrier again, so an unready GPU means no node health at all"
! grep -qE '^Before=.*pki-vm-measurements\.service' "$unit_dir/sp-nvidia-gpu-ready.service" \
    || fail "the barrier orders itself before the health surface again"
# The units that genuinely must not run before the GPU is ready still do not.
for gated in pki-cert-init pki-authority-sync; do
    grep -qE '^Requires=.*sp-nvidia-gpu-ready\.service' "$pki_unit_dir/$gated.service" \
        || fail "$gated no longer requires the barrier: a certificate must not be issued against unestablished hardware"
done

echo "health publisher tests passed"
