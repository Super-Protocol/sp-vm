#!/bin/bash

set -euo pipefail

BUILDROOT="/buildroot"
AZURE_GUEST_ATTEST_VERSION="0.2.0"
AZURE_GUEST_ATTEST_ASSET="azure-guest-attest-x86_64-unknown-linux-musl"
AZURE_GUEST_ATTEST_URL="https://github.com/Azure/azure-guest-attestation-sdk/releases/download/azure-guest-attest-v${AZURE_GUEST_ATTEST_VERSION}/${AZURE_GUEST_ATTEST_ASSET}"
AZURE_GUEST_ATTEST_SHA256="5e80495db126e6ce0bc476e46f85e0f6b56ab25317563f8a8ca37059333a678d"
AZURE_GUEST_ATTEST_PATH="${OUTPUTDIR}/tmp/${AZURE_GUEST_ATTEST_ASSET}"

# shellcheck disable=SC1091
source "$BUILDROOT/files/scripts/log.sh"

log_info "installing pinned azure-guest-attest ${AZURE_GUEST_ATTEST_VERSION}"
wget --https-only --quiet \
    --output-document="$AZURE_GUEST_ATTEST_PATH" \
    "$AZURE_GUEST_ATTEST_URL"
printf '%s  %s\n' "$AZURE_GUEST_ATTEST_SHA256" "$AZURE_GUEST_ATTEST_PATH" \
    | sha256sum --check --strict -
install -m 0755 "$AZURE_GUEST_ATTEST_PATH" \
    "$OUTPUTDIR/usr/bin/azure-guest-attest"
rm -f "$AZURE_GUEST_ATTEST_PATH"
