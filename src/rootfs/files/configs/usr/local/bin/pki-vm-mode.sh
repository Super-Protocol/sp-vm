#!/bin/bash

# Decide whether this node is a seed ("init") or a worker ("normal") and write
# the verdict to /etc/swarm/swarm-vm-mode.
#
# SUP-375: this used to be an `until [[ -s /sp/swarm/config.yaml ]]; do sleep 5;
# done` loop in the unit's ExecStartPre under TimeoutStartSec=infinity. When
# provider-config.service cannot populate /sp - the SUP-343 blob-expiry case -
# THIS unit is the one that held multi-user.target forever, even though
# provider-config.service itself is correctly bounded and fails on its own.
#
# The wait is kept, but bounded: /sp is populated by provider-config.service,
# which normally lands it within seconds, so failing on the first missing read
# would turn an ordinary ordering race into a console block on every boot. One
# bounded wait per attempt keeps the normal case silent and still lets systemd
# own the retry when the archive is really gone.

set -uo pipefail

readonly config="${SP_VM_MODE_CONFIG:-/sp/swarm/config.yaml}"
readonly output="${SP_VM_MODE_OUTPUT:-/etc/swarm/swarm-vm-mode}"
readonly helper="${SP_VM_MODE_HELPER:-/usr/local/bin/pki-authority/pki_configure_helper.py}"
readonly python_bin="${SP_VM_MODE_PYTHON:-/usr/bin/python3}"

# Must stay strictly below the attempt timeout in pki-vm-mode.service, or the
# wait alone would use up the attempt and the helper would never run.
readonly config_wait="${SP_VM_MODE_CONFIG_WAIT:-120}"
readonly poll_interval="${SP_VM_MODE_POLL_INTERVAL:-5}"

waited=0
while [[ ! -s "$config" ]]; do
    if (( waited >= config_wait )); then
        # EX_UNAVAILABLE: told apart from a parse failure of a config that IS
        # there, because the two have different owners - this one is
        # provider-config.service, and /sp is empty.
        echo "ERROR: ${config} was still absent or empty after ${config_wait}s;" \
             "provider-config.service has not populated /sp" >&2
        exit 69
    fi
    (( waited % 30 == 0 )) && echo "waiting for ${config} (${waited}s/${config_wait}s)"
    sleep "$poll_interval"
    waited=$((waited + poll_interval))
done

exec "$python_bin" "$helper" get-vm-mode --config "$config" --output "$output"
