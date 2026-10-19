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
#   - every outcome leaves something readable behind. On failure that is a
#     console diagnostic: on a -release guest, with no SSH and no readable
#     journal, the console is the only channel there is. The health file under
#     /run/sp-health is the machine-readable half, but today it is readable
#     only from inside the guest - so in practice on debug images. Nothing
#     exposes it to the fabric or the host orchestrator yet; that surface is
#     follow-up work alongside SUP-366, not a promise this script keeps.

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

# The full console block is ~25 lines. At RestartSec=60 forever that is ~2 KB a
# minute, and both Azure boot diagnostics and nova console-log keep only a
# bounded tail - so an outage of SUP-370's length (25 h) would push the original
# boot output out of the very logs QA collects as forensics. Print the block for
# the first few attempts, again whenever the reason changes, and then only once
# an hour; in between a single line keeps the outage visible.
readonly console_full_attempts="${SP_PKI_SYNC_CONSOLE_FULL_ATTEMPTS:-3}"
readonly console_full_every="${SP_PKI_SYNC_CONSOLE_FULL_EVERY:-60}"
readonly last_reason_file="${state_dir}/pki-authority-sync.last-reason"

# /dev/console on a confidential VM is outside the TEE boundary, and the tail
# below is another repository's debug output. pki-sync-client logs only
# error.message strings today, but one added log line there must not be able to
# put key material on the console, so the guard lives here rather than in a
# trust assumption about tee-pki.
readonly max_line_chars="${SP_PKI_SYNC_MAX_LINE_CHARS:-200}"

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

# Anything long enough to be a secret is dropped rather than truncated: a
# half-printed key is still a leak. PEM markers and long base64/hex runs are the
# shapes key material arrives in; a message with one is worth less than the
# guarantee that none reaches the console.
redact() {
    local line
    line="$(sanitize "${1-}")"
    if (( ${#line} > max_line_chars )); then
        printf '<suppressed: %s-char line>' "${#line}"
        return 0
    fi
    if [[ "$line" == *-----BEGIN* ]] || [[ "$line" =~ [A-Za-z0-9+/=]{40,} ]]; then
        printf '<suppressed: line may carry key material>'
        return 0
    fi
    printf '%s' "$line"
}

# True for the first few attempts, whenever the reason changes, and then once
# every console_full_every attempts.
console_wants_full_block() {
    local reason="$1" previous=""
    (( attempt <= console_full_attempts )) && return 0
    [[ -r "$last_reason_file" ]] && previous="$(cat "$last_reason_file" 2>/dev/null)"
    [[ "$reason" != "$previous" ]] && return 0
    (( console_full_every > 0 )) && (( attempt % console_full_every == 0 )) && return 0
    return 1
}

report_failure() {
    local reason="$1" line
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
            lines+=("  $(redact "$line")")
        done < <(tail -n "$error_tail_lines" "$attempt_log")
    fi
    lines+=(
        "systemd retries this unit on its own; boot is no longer blocked (SUP-372)."
        ""
    )

    # The journal keeps every block; only the console is rate-limited, because
    # only the console is a bounded shared buffer.
    printf '%s\n' "${lines[@]}" >&2
    if console_wants_full_block "$reason"; then
        console_say "${lines[@]}"
    else
        console_say "[pki-authority-sync] still failing (attempt ${attempt}): $(sanitize "$reason")"
    fi
    printf '%s\n' "$reason" >"$last_reason_file" 2>/dev/null || true
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
    # Forget the last failure reason, or a later identical one would be treated
    # as a repeat and never print its full block.
    rm -f "$last_reason_file" 2>/dev/null || true
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
