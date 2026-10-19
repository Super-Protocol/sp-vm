#!/bin/bash

# One bounded attempt at a boot-critical command, with a verdict that survives
# on a -release guest.
#
# SUP-375: four sp-vm units used to carry the same shape - an unbounded
# `until <cmd>; do sleep N; done` loop inside ExecStart under
# TimeoutStartSec=infinity, while being WantedBy=multi-user.target. Any one of
# them could keep a node in boot forever: the target was never reached, no
# timeout ever fired, :9180 kept answering 200, and the only trace was a
# journal line a release image cannot show. That is SUP-370.
#
# The fix is the same for all of them, so it lives here once instead of four
# times: systemd owns the retry (Restart=on-failure/RestartSec), and this script
# makes exactly ONE attempt and always terminates. Two properties follow, and
# both are the reason this is a shared runner rather than a shell one-liner per
# unit:
#
#   - the attempt is bounded by `timeout`, deliberately below the unit's
#     TimeoutStartSec. systemd kills the whole cgroup when that expires, and a
#     killed script reports nothing;
#   - every outcome leaves something readable behind. On failure that is a
#     console block: on a -release guest, with no SSH and no readable journal,
#     the console is the only channel there is. The health file under
#     /run/sp-health is the machine-readable half, readable only from inside the
#     guest today - nothing exposes it to the fabric or the host orchestrator
#     yet (SUP-376).
#
# Usage:
#   sp-boot-attempt.sh --unit <name.service> --timeout <seconds>
#                      [--action <what is being attempted>]
#                      [--impact <console line>]...
#                      [--detail <"label: value" console line>]...
#                      -- <command> [args...]
#
# Prototype: pki-authority-sync.sh (SUP-372), which is the unit this pattern was
# first proven on and is kept on its own copy for now - converging it onto this
# runner is a follow-up, not part of the diff that fixed the other three.

# Deliberately no `set -e`: every failure here has to reach write_state and the
# console before the script exits, so each one is handled explicitly.
set -uo pipefail

unit_name=""
attempt_timeout=""
action=""
declare -a impact_lines=()
declare -a detail_lines=()
declare -a attempt_cmd=()

die_usage() {
    # A malformed ExecStart would otherwise retry forever with its complaint on
    # a stderr nobody on a -release guest can read. Written straight to the
    # device because none of the script's state exists yet at this point.
    local message="[sp-boot-attempt] ERROR: $* (${unit_name:-<no --unit>})"
    echo "$message" >&2
    printf '%s\n' "$message" >>"${SP_BOOT_ATTEMPT_CONSOLE-/dev/console}" 2>/dev/null || true
    exit 64
}

while (( $# )); do
    case "$1" in
        --unit) unit_name="${2-}"; shift 2 || die_usage "--unit needs a value" ;;
        --timeout) attempt_timeout="${2-}"; shift 2 || die_usage "--timeout needs a value" ;;
        --action) action="${2-}"; shift 2 || die_usage "--action needs a value" ;;
        --impact) impact_lines+=("${2-}"); shift 2 || die_usage "--impact needs a value" ;;
        --detail) detail_lines+=("${2-}"); shift 2 || die_usage "--detail needs a value" ;;
        --) shift; attempt_cmd=("$@"); break ;;
        *) die_usage "unknown option '$1'" ;;
    esac
done

[[ -n "$unit_name" ]] || die_usage "--unit is required"
[[ "$attempt_timeout" =~ ^[0-9]+$ ]] || die_usage "--timeout must be a number of seconds"
(( ${#attempt_cmd[@]} )) || die_usage "no command given after --"
[[ -n "$action" ]] || action="${unit_name%.service}"

readonly slug="${unit_name%.service}"

# /run is tmpfs, so the health state is per-boot by construction: a reboot must
# not make a node look initialised before it has initialised again.
readonly state_dir="${SP_BOOT_ATTEMPT_STATE_DIR:-/run/sp-health}"
readonly state_file="${state_dir}/${slug}.json"
readonly attempt_log="${state_dir}/${slug}.log"
readonly attempt_file="${state_dir}/${slug}.attempt"
# Holds the reason CLASS, never the rendered reason: the rendered reason embeds
# the elapsed seconds, which move with network jitter between attempts, so
# keying the console throttle on it makes every repeat look like new information
# and the block prints every single attempt - exactly the flood this prevents.
readonly last_reason_file="${state_dir}/${slug}.last-reason"

readonly console="${SP_BOOT_ATTEMPT_CONSOLE-/dev/console}"
readonly timeout_cmd="${SP_TIMEOUT:-/usr/bin/timeout}"
readonly error_tail_lines="${SP_BOOT_ATTEMPT_ERROR_TAIL_LINES:-20}"

# The full console block is ~25 lines. At RestartSec=60 forever that is ~2 KB a
# minute, and both Azure boot diagnostics and nova console-log keep only a
# bounded tail - so an outage of SUP-370's length (25 h) would push the original
# boot output out of the very logs QA collects as forensics. Measured on the
# prototype: 4.06 MB -> 0.20 MB over 1500 attempts. Print the block for the
# first few attempts, again whenever the reason changes kind, then once an hour;
# in between a single line keeps the outage visible.
readonly console_full_attempts="${SP_BOOT_ATTEMPT_CONSOLE_FULL_ATTEMPTS:-3}"
readonly console_full_every="${SP_BOOT_ATTEMPT_CONSOLE_FULL_EVERY:-60}"

# /dev/console on a confidential VM is outside the TEE boundary, and the tail
# below is somebody else's debug output: pki-cert-generator runs at
# --log-level debug and swarm-init handles a GitHub token, so one added log line
# upstream must not be able to put key material on the console. The guard lives
# here rather than in a trust assumption about those programs.
#
# Key material is caught by SHAPE, token by token, not by line length. The line
# cap is only a bound on how much one line may take from a shared console
# buffer: a default-pino JSON object with a child context runs ~140 characters
# before the message, putting real error lines at 230-245, so a cap anywhere
# near that length drops precisely the lines that diagnose the node.
readonly max_line_chars="${SP_BOOT_ATTEMPT_MAX_LINE_CHARS:-2000}"
# 40 base64/hex characters in a row is not something a message contains by
# accident. Only HEX tokens keep a head: hex is the shape a CA fingerprint, an
# mrEnclave or a digest arrives in, and the head is what makes it comparable
# with the authority's - a CA mismatch is the SUP-370 root cause, so that token
# is the most useful thing on the console. Base64 is the shape key material
# arrives in, and a head of it was never diagnostic, so those are suppressed
# whole: a PEM body line is nothing BUT a token, and 8 characters from each of
# 25 of them is 200 uniformly-sampled characters of a private key.
readonly token_min_chars="${SP_BOOT_ATTEMPT_TOKEN_MIN_CHARS:-40}"
readonly token_head_chars="${SP_BOOT_ATTEMPT_TOKEN_HEAD_CHARS:-8}"

log() { echo "[${slug}] $*"; }
log_err() { echo "[${slug}] ERROR: $*" >&2; }

# The console is a shared, line-oriented device with no quoting, and the health
# file is JSON built without a JSON library: collapse everything to printable
# single-line text so neither can be corrupted by command output.
sanitize() {
    printf '%s' "${1-}" | tr '\n\r\t' '   ' | tr -cd '[:print:]' | sed 's/[\\"]/ /g'
}

write_state() {
    local state="$1" reason="$2" exit_code="$3" reason_class="${4:-$1}" line first=1
    install -d -m 0755 "$state_dir" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "unit": "%s",\n' "$unit_name"
        printf '  "state": "%s",\n' "$state"
        printf '  "attempt": %s,\n' "$attempt"
        printf '  "exit_code": %s,\n' "${exit_code:-null}"
        printf '  "reason": "%s",\n' "$(sanitize "$reason")"
        printf '  "reason_class": "%s",\n' "$(sanitize "$reason_class")"
        # The same --detail lines the console block carries: the paths and
        # owners that make a verdict actionable, in the half a program can read.
        printf '  "details": ['
        for line in ${detail_lines[@]+"${detail_lines[@]}"}; do
            (( first )) || printf ', '
            printf '"%s"' "$(sanitize "$line")"
            first=0
        done
        printf '],\n'
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

# Matches a line that IS a PEM delimiter, not one that merely mentions a marker
# inside a message: a JSON log line quoting "-----BEGIN CERTIFICATE-----" must
# not open a block and swallow the rest of the tail. redact() drops such a line
# on its own.
#
# The label class carries "-" because RFC 7468 allows it inside a label. A label
# the matcher rejects is worse than it sounds: the block never opens, so the body
# falls through to redact(), where the short final body line is below
# token_min_chars and prints in full. A leading "-" in a bracket expression is
# literal.
is_pem_delimiter() {
    [[ "${1-}" =~ ^[[:space:]]*-----(BEGIN|END)[-[:space:]A-Za-z0-9]*-----[[:space:]]*$ ]]
}
is_pem_end() {
    [[ "${1-}" =~ ^[[:space:]]*-----END[-[:space:]A-Za-z0-9]*-----[[:space:]]*$ ]]
}

# Redacts the key-shaped TOKENS out of a line and keeps the prose around them:
# the message is what diagnoses the node, and dropping the whole line to be rid
# of one token throws the diagnosis away with it. A line that mentions a PEM
# marker at all is the exception and goes whole.
#
# Whole PEM blocks are handled by the caller, not here: this runs inside a
# command substitution, so any state it kept would die with the subshell.
redact() {
    local line rest out tok pattern
    line="$(sanitize "${1-}")"
    if [[ "$line" == *-----BEGIN* ]] || [[ "$line" == *-----END* ]]; then
        printf '<suppressed: PEM marker>'
        return 0
    fi
    if (( ${#line} > max_line_chars )); then
        printf '<suppressed: %s-char line>' "${#line}"
        return 0
    fi
    pattern="[A-Za-z0-9+/=]{${token_min_chars},}"
    rest="$line"
    out=""
    while [[ "$rest" =~ $pattern ]]; do
        tok="${BASH_REMATCH[0]}"
        if [[ "$tok" =~ ^[0-9a-fA-F]+$ ]]; then
            out+="${rest%%"$tok"*}<${tok:0:$token_head_chars}... ${#tok}-char token redacted>"
        else
            out+="${rest%%"$tok"*}<${#tok}-char token redacted>"
        fi
        rest="${rest#*"$tok"}"
    done
    printf '%s%s' "$out" "$rest"
}

# True for the first few attempts, whenever the failure changes KIND, and then
# once every console_full_every attempts.
console_wants_full_block() {
    local reason_class="$1" previous=""
    (( attempt <= console_full_attempts )) && return 0
    [[ -r "$last_reason_file" ]] && previous="$(cat "$last_reason_file" 2>/dev/null)"
    [[ "$reason_class" != "$previous" ]] && return 0
    (( console_full_every > 0 )) && (( attempt % console_full_every == 0 )) && return 0
    return 1
}

report_failure() {
    local reason="$1" reason_class="$2" line
    local -a lines=(
        ""
        "*** ${unit_name} FAILED (attempt ${attempt}) ***"
    )
    for line in ${impact_lines[@]+"${impact_lines[@]}"}; do
        lines+=("$(sanitize "$line")")
    done
    lines+=("reason:    $(sanitize "$reason")")
    for line in ${detail_lines[@]+"${detail_lines[@]}"}; do
        lines+=("$(sanitize "$line")")
    done
    if [[ -s "$attempt_log" ]]; then
        lines+=("last ${error_tail_lines} line(s) of the attempt:")
        local -a tail_lines=()
        while IFS= read -r line; do
            tail_lines+=("$line")
        done < <(tail -n "$error_tail_lines" "$attempt_log")

        # A PEM body line is nothing but base64, and its last line is short
        # enough not to be a token at all - no per-line rule can catch that one.
        # So the block is suppressed as a block, BEGIN through END.
        local in_pem=0 announced=0
        # The window can open inside a block whose BEGIN has already scrolled
        # out of it. If the first delimiter we meet is an END, everything before
        # it is key body.
        for line in ${tail_lines[@]+"${tail_lines[@]}"}; do
            is_pem_delimiter "$line" || continue
            is_pem_end "$line" && in_pem=1
            break
        done
        for line in ${tail_lines[@]+"${tail_lines[@]}"}; do
            if is_pem_delimiter "$line"; then
                in_pem=1
            fi
            if (( in_pem )); then
                if (( ! announced )); then
                    lines+=("  <suppressed: PEM block>")
                    announced=1
                fi
                if is_pem_end "$line"; then
                    in_pem=0
                    announced=0
                fi
                continue
            fi
            lines+=("  $(redact "$line")")
        done
    fi
    lines+=(
        "systemd retries this unit on its own; boot is no longer blocked (SUP-375)."
        ""
    )

    # The journal keeps every block; only the console is rate-limited, because
    # only the console is a bounded shared buffer.
    printf '%s\n' "${lines[@]}" >&2
    if console_wants_full_block "$reason_class"; then
        console_say "${lines[@]}"
    else
        console_say "[${slug}] still failing (attempt ${attempt}): $(sanitize "$reason")"
    fi
    printf '%s\n' "$reason_class" >"$last_reason_file" 2>/dev/null || true
}

install -d -m 0755 "$state_dir" 2>/dev/null || true
# Truncated here, not where `tee` opens it: the missing-command path and a
# signal arriving before the pipeline both report without ever running the
# command, and would otherwise print the PREVIOUS attempt's output under this
# attempt's "last N line(s) of the attempt" heading. On a -release guest that
# block is the whole diagnosis, so a stale tail is worse than no tail.
: >"$attempt_log" 2>/dev/null || true

attempt=1
if [[ -r "$attempt_file" ]]; then
    previous="$(tr -cd '[:digit:]' <"$attempt_file")"
    [[ -n "$previous" ]] && attempt=$((previous + 1))
fi
printf '%s\n' "$attempt" >"$attempt_file" 2>/dev/null || true

write_state attempting "${action} attempt ${attempt} in progress" "" attempting

# systemd's TimeoutStartSec kills this cgroup without warning; catching the
# signal is the only way the console still learns which attempt was cut short.
on_signal() {
    local reason="attempt ${attempt} terminated by signal before it finished"
    write_state failed "$reason" 143 signal
    report_failure "$reason" signal
    exit 143
}
trap on_signal TERM INT

if ! command -v "${attempt_cmd[0]}" >/dev/null 2>&1; then
    reason="${attempt_cmd[0]} is missing from this image"
    write_state failed "$reason" 127 missing-command
    report_failure "$reason" missing-command
    exit 127
fi

log "attempt ${attempt}: ${action}, bounded to ${attempt_timeout}s"

started=$SECONDS
"$timeout_cmd" --kill-after=10s "${attempt_timeout}s" "${attempt_cmd[@]}" 2>&1 | tee "$attempt_log"
rc=${PIPESTATUS[0]}
elapsed=$((SECONDS - started))

trap - TERM INT

if (( rc == 0 )); then
    write_state ok "${action} succeeded on attempt ${attempt} after ${elapsed}s" 0 ok
    # Forget the last failure reason, or a later identical one would be treated
    # as a repeat and never print its full block.
    rm -f "$last_reason_file" 2>/dev/null || true
    log "attempt ${attempt} succeeded after ${elapsed}s"
    exit 0
fi

# 124 is `timeout`'s verdict; 137 means the command ignored SIGTERM and was
# killed. Both are the SUP-370 failure mode - something that answers but never
# finishes - and must not be reported as a plain non-zero exit.
if (( rc == 124 || rc == 137 )); then
    reason="${action} did not finish within ${attempt_timeout}s"
    reason_class="timeout"
else
    reason="${action} exited with code ${rc} after ${elapsed}s"
    # The class deliberately drops ${elapsed}: it is the per-attempt detail the
    # health file and the journal keep, and the one thing that must not reach
    # the throttle key.
    reason_class="exit-${rc}"
fi

write_state failed "$reason" "$rc" "$reason_class"
report_failure "$reason" "$reason_class"
exit 1
