#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR
# NODEJS_VERSION
# NODEJS_DEB_SHA256

BUILDROOT="/buildroot";
source "${BUILDROOT}/files/scripts/chroot.sh";

PACKAGE_FILENAME="nodejs_${NODEJS_VERSION}_amd64.deb";
PACKAGE_PATH="${OUTPUTDIR}/tmp/${PACKAGE_FILENAME}";

wget "https://deb.nodesource.com/node_${NODEJS_VERSION%%.*}.x/pool/main/n/nodejs/${PACKAGE_FILENAME}" \
    -O "$PACKAGE_PATH";
printf '%s  %s\n' "$NODEJS_DEB_SHA256" "$PACKAGE_PATH" | sha256sum --check --strict -;

chroot_init;
chroot "${OUTPUTDIR}" apt-get install -y --no-install-recommends "/tmp/${PACKAGE_FILENAME}";
chroot_deinit;
rm -f "$PACKAGE_PATH";
