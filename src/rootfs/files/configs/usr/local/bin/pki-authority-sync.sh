#!/bin/bash

# One bounded PKI authority sync attempt.
#
# SUP-372: the retry used to live inside the unit's ExecStart (`until ...;
# sleep 60; done`) with TimeoutStartSec=infinity, so a node the authority would
# not sign never left the boot transaction: multi-user.target was never
# reached, no timeout ever fired, and the only trace was a journal line that a
# -release image cannot show. systemd now owns the retry
# (Restart=on-failure/RestartSec), which makes two properties mandatory here:
#
#   - this script always terminates. The attempt is bounded by `timeout` well
#     below the unit's TimeoutStartSec, because systemd kills the whole cgroup
#     when that expires and a killed script reports nothing;
#   - every outcome leaves something readable behind: a health file under
#     /run that the node and the host orchestrator can poll, and - on failure -
#     a diagnostic on the console, the only channel a release guest has.

# Deliberately no `set -e`: every failure here has to reach write_state and the
# console before the script exits, so each one is handled explicitly.
set -uo pipefail

readonly unit_name="pki-authority-sync.service"

readonly node_bin="${SP_PKI_SYNC_NODE:-/usr/bin/node}"
readonly sync_client="${SP_PKI_SYNC_CLIENT:-/usr/bin/pki-sync-client}"
readonly secrets_config="${SP_PKI_SYNC_SECRETS_CONFIG:-/etc/super/pki-authority-sync/secrets-config.yaml}"
readonly swarm_env="${SP_PKI_SYNC_SWARM_ENV:-/etc/swarm/sync-client-config.yaml}"
readonly certs_dir="${SP_PKI_SYNC_CERTS_DIR:-/etc/super/certs/vm}"
readonly network_type_file="${SP_PKI_SYNC_NETWORK_TYPE_FILE:-/etc/swarm/swarm-network-type}"
readonly log_level="${SP_PKI_SYNC_LOG_LEVEL:-debug}"

# /run is tmpfs, so the health state is per-boot by construction: a reboot must
# not make a node look synced before it has synced again.
readonly state_dir="${SP_PKI_SYNC_STATE_DIR:-/run/sp-health}"
readonly state_file="${state_dir}/pki-authority-sync.json"
readonly attempt_log="${state_dir}/pki-authority-sync.log"
readonly attempt_file="${state_dir}/pki-authority-sync.attempt"

readonly console="${SP_PKI_SYNC_CONSOLE:-/dev/console}"
readonly timeout_cmd="${SP_TIMEOUT:-/usr/bin/timeout}"
# Keep in sync with TimeoutStartSec in pki-authority-sync.service: that value
# must stay strictly larger, or systemd kills this script before it reports.
readonly attempt_timeout="${SP_PKI_SYNC_ATTEMPT_TIMEOUT:-240}"
readonly error_tail_lines="${SP_PKI_SYNC_ERROR_TAIL_LINES:-20}"

log() { echo "[pki-authority-sync] $*"; }
log_err() { echo "[pki-authority-sync] ERROR: $*" >&2; }

# The console is a shared, line-oriented device with no quoting, and the health
# file is JSON built without a JSON library: collapse everything to printable
# single-line text so neither can be corrupted by client output.
sanitize() {
    printf '%s' "${1-}" | tr '\n\r\t' '   ' | tr -cd '[:print:]' | sed 's/[\\"]/ /g'
}

# Parsed with awk rather than PyYAML so the attempt stays diagnosable even when
# nothing but coreutils is available this early in boot. pki_configure_helper.py
# renders the file with yaml.dump, so pki_authority.servers is always a
# block sequence; the last rule leaves it again at the next sibling key, which
# is what keeps a caBundle literal block whose lines begin with "-" out of the
# list.
authority_servers() {
    [[ -r "$swarm_env" ]] || return 0
    awk '
        /^[^[:space:]]/ { in_authority = ($0 ~ /^pki_authority:/); in_servers = 0; next }
        in_authority && /^[[:space:]]+servers:[[:space:]]*$/ { in_servers = 1; next }
        in_authority && in_servers && /^[[:space:]]+-[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+-[[:space:]]*/, "", value)
            gsub(/^["'"'"']|["'"'"']$/, "", value)
            if (value != "") print value
            next
        }
        in_authority && /^[[:space:]]+[^[:space:]-]/ { in_servers = 0 }
    ' "$swarm_env" 2>/dev/null || true
}

servers_json() {
    local first=1 server
    printf '['
    while IFS= read -r server; do
        [[ -n "$server" ]] || continue
        (( first )) || printf ', '
        printf '"%s"' "$(sanitize "$server")"
        first=0
    done <<<"${1-}"
    printf ']'
}

write_state() {
    local state="$1" reason="$2" exit_code="$3"
    install -d -m 0755 "$state_dir" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "unit": "%s",\n' "$unit_name"
        printf '  "state": "%s",\n' "$state"
        printf '  "attempt": %s,\n' "$attempt"
        printf '  "exit_code": %s,\n' "${exit_code:-null}"
        printf '  "reason": "%s",\n' "$(sanitize "$reason")"
        printf '  "authority_servers": %s,\n' "$(servers_json "$servers")"
        printf '  "attempt_log": "%s",\n' "$attempt_log"
        printf '  "updated_at": "%s"\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '}\n'
    } >"${state_file}.tmp" 2>/dev/null \
        && mv -f "${state_file}.tmp" "$state_file" 2>/dev/null \
        || log_err "could not publish health state to ${state_file}"
}

# A release guest has no SSH and no readable journal, so the console is the only
# place an operator can see why the node is not serving. Never fail on it: the
# device is absent in containers and in the rootfs tests.
console_say() {
    [[ -n "$console" ]] || return 0
    printf '%s\n' "$@" >>"$console" 2>/dev/null || true
}

report_failure() {
    local reason="$1"
    local -a lines=(
        ""
        "*** ${unit_name} FAILED (attempt ${attempt}) ***"
        "This node has no PKI certificates and no swarm key, so swarm-db,"
        "swarm-node and swarm-services stay down and :9443 never opens."
        "reason:    $(sanitize "$reason")"
        "authority: $(sanitize "${servers:-<none configured>}")"
    )
    if [[ -s "$attempt_log" ]]; then
        lines+=("last ${error_tail_lines} line(s) of the attempt:")
        while IFS= read -r line; do
            lines+=("  $(sanitize "$line")")
        done < <(tail -n "$error_tail_lines" "$attempt_log")
    fi
    lines+=(
        "systemd retries this unit on its own; boot is no longer blocked (SUP-372)."
        ""
    )
    console_say "${lines[@]}"
    printf '%s\n' "${lines[@]}" >&2
}

install -d -m 0755 "$state_dir" 2>/dev/null || true

attempt=1
if [[ -r "$attempt_file" ]]; then
    previous="$(tr -cd '[:digit:]' <"$attempt_file")"
    [[ -n "$previous" ]] && attempt=$((previous + 1))
fi
printf '%s\n' "$attempt" >"$attempt_file" 2>/dev/null || true

servers="$(authority_servers)"
servers_oneline="$(printf '%s' "$servers" | tr '\n' ' ')"

write_state attempting "sync attempt ${attempt} in progress" ""

# systemd's TimeoutStartSec kills this cgroup without warning; catching the
# signal is the only way the console still learns which attempt was cut short.
on_signal() {
    local reason="attempt ${attempt} terminated by signal before it finished"
    write_state failed "$reason" 143
    report_failure "$reason"
    exit 143
}
trap on_signal TERM INT

if [[ ! -r "$sync_client" ]]; then
    reason="sync client ${sync_client} is missing from this image"
    write_state failed "$reason" 127
    report_failure "$reason"
    exit 127
fi

log "attempt ${attempt}: syncing with authority [${servers_oneline:-none configured}], bounded to ${attempt_timeout}s"

started=$SECONDS
"$timeout_cmd" --kill-after=10s "${attempt_timeout}s" \
    "$node_bin" "$sync_client" sync \
    --config "$secrets_config" \
    --swarm-env "$swarm_env" \
    --save-certs-to-dir "$certs_dir" \
    --save-certs-prefix vm \
    --network-type-file "$network_type_file" \
    --disable-server-identity-check \
    --log-level "$log_level" 2>&1 | tee "$attempt_log"
rc=${PIPESTATUS[0]}
elapsed=$((SECONDS - started))

trap - TERM INT

if (( rc == 0 )); then
    write_state ok "synced with the authority on attempt ${attempt} after ${elapsed}s" 0
    log "attempt ${attempt} succeeded after ${elapsed}s"
    exit 0
fi

# 124 is `timeout`'s verdict; 137 means the client ignored SIGTERM and was
# killed. Both are the SUP-372 failure mode - an authority that answers but
# never signs - and must not be reported as a plain non-zero exit.
if (( rc == 124 || rc == 137 )); then
    reason="the authority did not complete the sync within ${attempt_timeout}s"
else
    reason="pki-sync-client exited with code ${rc} after ${elapsed}s"
fi

write_state failed "$reason" "$rc"
report_failure "$reason"
exit 1
