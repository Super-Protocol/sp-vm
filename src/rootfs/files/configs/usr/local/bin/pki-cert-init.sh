#!/bin/bash

# Render the cert-gen config and generate this seed's PKI chain - once.
#
# SUP-375: the generation used to be an `until /usr/bin/pki-cert-generator
# generate-chain ...; do sleep 60; done` loop in ExecStart under
# TimeoutStartSec=infinity. A seed that could not build its chain held
# multi-user.target forever and took swarm-init and everything behind it with
# it, the same way a worker did through pki-authority-sync (SUP-370/SUP-372).
#
# The `configure` step was an ExecStartPre, which is a blind spot on a -release
# guest: a unit that fails before ExecStart runs produces no console output at
# all. It is folded in here so a malformed template is as visible as a refused
# chain - this is the seed, so its silence costs the whole cloud.

set -uo pipefail

readonly template="${SP_PKI_CERT_INIT_TEMPLATE:-/etc/super/pki-cert-generator/cert-gen-config-template.yaml}"
readonly rendered="${SP_PKI_CERT_INIT_CONFIG:-/etc/super/pki-cert-generator/cert-gen-config.yaml}"
readonly helper="${SP_PKI_CERT_INIT_HELPER:-/usr/local/bin/pki-authority/pki_configure_helper.py}"
readonly python_bin="${SP_PKI_CERT_INIT_PYTHON:-/usr/bin/python3}"
readonly generator="${SP_PKI_CERT_INIT_GENERATOR:-/usr/bin/pki-cert-generator}"
readonly log_level="${SP_PKI_CERT_INIT_LOG_LEVEL:-debug}"

if ! "$python_bin" "$helper" configure --template "$template" --output "$rendered"; then
    # EX_CONFIG: the template or the swarm key, not the chain itself. Kept
    # distinct so the console names the step that actually failed.
    echo "ERROR: could not render ${rendered} from ${template}" >&2
    exit 78
fi

exec "$generator" generate-chain -c "$rendered" --log-level "$log_level"
