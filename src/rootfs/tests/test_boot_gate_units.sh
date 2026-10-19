#!/usr/bin/env bash

# SUP-375: no sp-vm unit may gate multi-user.target with an unbounded retry
# again.
#
# Four units carried the identical shape - `TimeoutStartSec=infinity` wrapped
# around an `until <cmd>; do sleep N; done` loop in ExecStart, while being
# WantedBy=multi-user.target. Any one of them could hold a node in boot forever
# with :9180 still answering 200 and nothing raising an alarm (SUP-370). This
# file is the contract for all of them at once, plus a tree-wide guard so a new
# unit cannot quietly reintroduce the shape.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
if [[ -n "${SP_BOOT_GATE_TEST_INSTALLED_ROOT:-}" ]]; then
    # On a built rootfs every unit has been collapsed into one directory.
    unit_dirs=("$SP_BOOT_GATE_TEST_INSTALLED_ROOT/etc/systemd/system")
    bin_dir="$SP_BOOT_GATE_TEST_INSTALLED_ROOT/usr/local/bin"
else
    config_dir="$repository_root/src/rootfs/files/configs"
    unit_dirs=("$config_dir/etc/systemd/system" "$config_dir/pki-service/systemd")
    bin_dir="$config_dir/usr/local/bin"
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

unit_path() {
    local name="$1" dir
    for dir in "${unit_dirs[@]}"; do
        [[ -f "$dir/$name" ]] && { printf '%s\n' "$dir/$name"; return 0; }
    done
    return 1
}

all_units() {
    local dir
    for dir in "${unit_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        find "$dir" -maxdepth 1 -name '*.service' -printf '%f\n'
    done | sort -u
}

unit_value() {
    sed -n "s/^$2=//p" "$1" | tail -n1
}

# ExecStart=/path \<newline>    --flag ... is one logical line to systemd, so
# every check on a start command has to see it that way too.
logical_lines() {
    sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$1"
}

# The units whose ExecStart is a boot-critical command that can fail: each one
# must make a single bounded attempt and leave the retry to systemd.
gate_units=(
    swarm-init.service
    pki-cert-init.service
    pki-vm-mode.service
    pki-authority-sync.service
)

# --- tree-wide: the shape itself must be gone ---

# sp-nvidia-gpu-ready.service is the one unit allowed to keep
# TimeoutStartSec=infinity: its ExecStart is internally bounded by
# SP_NVIDIA_READY_TIMEOUT, so it always terminates on its own. The allowance is
# checked, not assumed - if that bound ever disappears the unit joins the family
# of boot gates this file exists to prevent.
infinity_allowlist=(sp-nvidia-gpu-ready.service)

for unit_name in $(all_units); do
    path="$(unit_path "$unit_name")" || continue
    grep -q '^TimeoutStartSec=infinity' "$path" || continue
    allowed=0
    for allowed_unit in "${infinity_allowlist[@]}"; do
        [[ "$unit_name" == "$allowed_unit" ]] && allowed=1
    done
    (( allowed )) \
        || fail "$unit_name has TimeoutStartSec=infinity: an unbounded start job is a boot gate (SUP-370/SUP-375)"
    bounded_bin="$bin_dir/sp-nvidia-gpu-ready"
    [[ -r "$bounded_bin" ]] \
        || fail "$unit_name is allowed TimeoutStartSec=infinity only because $bounded_bin bounds itself, and that file is gone"
    grep -q 'SP_NVIDIA_READY_TIMEOUT' "$bounded_bin" \
        || fail "$unit_name keeps TimeoutStartSec=infinity but $bounded_bin no longer bounds its own runtime"
done

# A retry loop inside a start command is the defect, wherever it lives: systemd
# cannot fail a job that never returns.
for unit_name in $(all_units); do
    path="$(unit_path "$unit_name")" || continue
    offenders="$(logical_lines "$path" \
        | grep -E '^(ExecStart|ExecStartPre|ExecStartPost)=' \
        | grep -E '\buntil\b.*\bsleep\b' || true)"
    [[ -z "$offenders" ]] \
        || fail "$unit_name has a retry loop back inside a start command: $offenders"
done

# --- per gate unit: one bounded attempt, systemd owns the retry ---

for unit_name in "${gate_units[@]}"; do
    path="$(unit_path "$unit_name")" || fail "$unit_name is missing from ${unit_dirs[*]}"

    start_timeout="$(unit_value "$path" TimeoutStartSec)"
    [[ "$start_timeout" =~ ^[0-9]+$ ]] \
        || fail "$unit_name: TimeoutStartSec must be a bounded number of seconds, got '${start_timeout:-<unset>}'"
    (( start_timeout > 0 && start_timeout <= 900 )) \
        || fail "$unit_name: TimeoutStartSec=${start_timeout} is not the bounded few minutes SUP-375 asks for"

    [[ "$(unit_value "$path" Restart)" == "on-failure" ]] \
        || fail "$unit_name: the retry must belong to systemd (Restart=on-failure), not to ExecStart"
    restart_sec="$(unit_value "$path" RestartSec)"
    [[ "$restart_sec" =~ ^[0-9]+$ ]] && (( restart_sec >= 10 )) \
        || fail "$unit_name: RestartSec must back the retry off, got '${restart_sec:-<unset>}'"

    # StartLimitIntervalSec belongs to [Unit]. Spelled StartLimitInterval= or
    # placed in [Service] it is silently ignored, and systemd gives up on the
    # unit entirely after the default burst - which is the boot gate again,
    # only quieter.
    [[ "$(unit_value "$path" StartLimitIntervalSec)" == "0" ]] \
        || fail "$unit_name: StartLimitIntervalSec=0 is required, or systemd stops retrying altogether"
    awk '/^\[/{section=$0} /^StartLimitIntervalSec=/{if (section != "[Unit]") exit 1}' "$path" \
        || fail "$unit_name: StartLimitIntervalSec is outside [Unit], where systemd ignores it"

    [[ "$(grep -c '^WantedBy=multi-user.target$' "$path")" == "1" ]] \
        || fail "$unit_name: the unit must still be installed into multi-user.target"

    # Every start command has to be a single invocation that returns. A shell
    # wrapper is how the loop got in last time.
    while IFS= read -r exec_line; do
        [[ -n "$exec_line" ]] || continue
        [[ ! "$exec_line" =~ (^|/)(ba|da|z)?sh[[:space:]]+-c ]] \
            || fail "$unit_name: '$exec_line' runs a shell snippet; put it in a script the tests can reach"
    done < <(logical_lines "$path" | sed -n 's/^ExecStart=//p')
done

# --- a late success must revive what the bounded failure took down ---

# When a bounded attempt fails at boot, every unit that Requires= it loses its
# start job to JOB_DEPENDENCY - and Restart= cannot revive a unit whose start
# job never ran. So a gate unit owes an explicit start to the units behind it
# that nobody else will revive: its direct reverse-Requires, and transitively
# through any of those that has no revival of its own.
reverse_requires() {
    local target="$1" unit_name path
    for unit_name in $(all_units); do
        path="$(unit_path "$unit_name")" || continue
        grep -E '^Requires=' "$path" | grep -qw -- "$target" && printf '%s\n' "$unit_name"
    done
}

has_revival() {
    local path
    path="$(unit_path "$1")" || return 1
    logical_lines "$path" | grep -qE '^ExecStartPost=.*systemctl.* start '
}

revival_closure() {
    local -a queue=() seen=()
    local current candidate known
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && queue+=("$candidate")
    done < <(reverse_requires "$1")
    while (( ${#queue[@]} )); do
        current="${queue[0]}"
        queue=("${queue[@]:1}")
        known=0
        for candidate in ${seen[@]+"${seen[@]}"}; do
            [[ "$candidate" == "$current" ]] && known=1
        done
        (( known )) && continue
        seen+=("$current")
        # A unit with its own ExecStartPost revival takes care of the chain
        # behind it; recursing past it would only duplicate that.
        has_revival "$current" && continue
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] && queue+=("$candidate")
        done < <(reverse_requires "$current")
    done
    printf '%s\n' ${seen[@]+"${seen[@]}"} | sort -u
}

for unit_name in "${gate_units[@]}"; do
    path="$(unit_path "$unit_name")" || fail "$unit_name is missing"
    exec_start_post="$(logical_lines "$path" | grep -E '^ExecStartPost=' || true)"
    while IFS= read -r dependent; do
        [[ -n "$dependent" ]] || continue
        [[ "$exec_start_post" == *"$dependent"* ]] \
            || fail "$unit_name: a post-boot success does not revive $dependent, whose start job dies with it"
    done < <(revival_closure "$unit_name")

    # A name that does not resolve to a unit makes `systemctl start` a silent
    # no-op, which looks exactly like a working revival.
    for named in $(grep -oE '[a-z0-9@.-]+\.service' <<<"$exec_start_post" | sort -u); do
        [[ "$named" == "$unit_name" ]] && fail "$unit_name: ExecStartPost restarts the unit itself"
        unit_path "$named" >/dev/null \
            || fail "$unit_name: ExecStartPost names $named, which is not a unit in this image"
    done
done

# --- the runner's bound must leave systemd room to hear the verdict ---

runner="$bin_dir/sp-boot-attempt.sh"
[[ -x "$runner" ]] || fail "sp-boot-attempt.sh is missing or not executable"

for unit_name in swarm-init.service pki-cert-init.service pki-vm-mode.service; do
    path="$(unit_path "$unit_name")" || fail "$unit_name is missing"
    exec_start="$(logical_lines "$path" | sed -n 's/^ExecStart=//p' | tail -n1)"
    [[ "$exec_start" == /usr/local/bin/sp-boot-attempt.sh* ]] \
        || fail "$unit_name: ExecStart must be the shared bounded runner, got '$exec_start'"
    [[ "$exec_start" == *"--unit $unit_name"* ]] \
        || fail "$unit_name: the runner is not told which unit it is reporting for"

    attempt_timeout="$(grep -oE -- '--timeout [0-9]+' <<<"$exec_start" | awk '{print $2}')"
    [[ "$attempt_timeout" =~ ^[0-9]+$ ]] \
        || fail "$unit_name: the runner is not given a bounded --timeout"
    start_timeout="$(unit_value "$path" TimeoutStartSec)"
    # --kill-after=10s of SIGKILL grace sits between the two, and the runner
    # still has to write the health file and the console block afterwards.
    (( attempt_timeout + 10 < start_timeout )) \
        || fail "$unit_name: --timeout ${attempt_timeout}s leaves no room under TimeoutStartSec=${start_timeout}s; systemd would kill the runner before it reports"

    # Every gate unit must say what breaks while it is failing: on a -release
    # guest the console block is the whole diagnosis.
    [[ "$exec_start" == *"--impact "* ]] \
        || fail "$unit_name: the console block would not say what stays down while this unit fails"
done

# pki-vm-mode's wait for /sp lives inside its own script, and must stay well
# inside the attempt it runs in - otherwise the wait eats the attempt and the
# helper never runs.
vm_mode_script="$bin_dir/pki-vm-mode.sh"
[[ -x "$vm_mode_script" ]] || fail "pki-vm-mode.sh is missing or not executable"
config_wait="$(sed -n 's/^readonly config_wait="\${SP_VM_MODE_CONFIG_WAIT:-\([0-9]*\)}".*/\1/p' "$vm_mode_script")"
[[ "$config_wait" =~ ^[0-9]+$ ]] || fail "could not read pki-vm-mode.sh's config wait bound"
vm_mode_path="$(unit_path pki-vm-mode.service)"
vm_mode_attempt="$(logical_lines "$vm_mode_path" | sed -n 's/^ExecStart=//p' | grep -oE -- '--timeout [0-9]+' | awk '{print $2}')"
(( config_wait < vm_mode_attempt )) \
    || fail "pki-vm-mode.sh waits ${config_wait}s inside a ${vm_mode_attempt}s attempt: the helper would never run"

if command -v systemd-analyze >/dev/null 2>&1; then
    verify_dir="$(mktemp -d -t sp-boot-gate-verify.XXXXXXXX)"
    trap 'rm -rf "$verify_dir"' EXIT
    for unit_name in "${gate_units[@]}"; do
        path="$(unit_path "$unit_name")" || continue
        cp "$path" "$verify_dir/"
    done
    verify_output="$(systemd-analyze verify --root=/ "$verify_dir"/*.service 2>&1 || true)"
    # Unresolvable siblings and absent binaries are expected off a real image;
    # a rejected directive is not.
    if grep -qiE 'refusing|not allowed|invalid|unknown (lvalue|section)' <<<"$verify_output"; then
        fail "systemd rejected a unit: $verify_output"
    fi
fi

echo "boot-gate unit contract tests passed"
