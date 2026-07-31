#!/usr/bin/env bash

set -euo pipefail

PCCS_DIR="${PCCS_DIR:-/opt/intel/sgx-dcap-pccs}"
PCCS_USER="${PCCS_USER:-pccs}"
PCCS_GROUP="${PCCS_GROUP:-pccs}"
KEY_DIR="${PCCS_DIR}/ssl_key"
PRIVATE_KEY="${KEY_DIR}/private.pem"
CSR="${KEY_DIR}/csr.pem"
CERTIFICATE="${KEY_DIR}/file.crt"

if [[ -s "$PRIVATE_KEY" && -s "$CSR" && -s "$CERTIFICATE" ]]; then
    exit 0
fi

install -d -o "$PCCS_USER" -g "$PCCS_GROUP" -m 0750 "$KEY_DIR"

temporary_dir="$(mktemp -d "${KEY_DIR}/.generate.XXXXXXXX")"
function cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT

umask 077
openssl genrsa -out "${temporary_dir}/private.pem" 2048
openssl req \
    -new \
    -key "${temporary_dir}/private.pem" \
    -out "${temporary_dir}/csr.pem" \
    -subj '/CN=localhost'
openssl x509 \
    -req \
    -days 3650 \
    -in "${temporary_dir}/csr.pem" \
    -signkey "${temporary_dir}/private.pem" \
    -out "${temporary_dir}/file.crt"

chown "${PCCS_USER}:${PCCS_GROUP}" \
    "${temporary_dir}/private.pem" \
    "${temporary_dir}/csr.pem" \
    "${temporary_dir}/file.crt"
chmod 0600 "${temporary_dir}/private.pem" "${temporary_dir}/csr.pem"
chmod 0644 "${temporary_dir}/file.crt"

mv -f "${temporary_dir}/private.pem" "$PRIVATE_KEY"
mv -f "${temporary_dir}/csr.pem" "$CSR"
mv -f "${temporary_dir}/file.crt" "$CERTIFICATE"
