#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

BUILDROOT="/buildroot";
NODEJS_VERSION="24.18.0-1nodesource1";
NODEJS_DEB_SHA256="9d80b9f2728e92b9bcd7fcef7124d9139dadefc2289170a7fcc6cb1ba5271e7c";
source "${BUILDROOT}/files/scripts/chroot.sh";

PACKAGE_FILENAME="nodejs_${NODEJS_VERSION}_amd64.deb";
PACKAGE_PATH="${OUTPUTDIR}/tmp/${PACKAGE_FILENAME}";

chroot_init;
wget "https://deb.nodesource.com/node_${NODEJS_VERSION%%.*}.x/pool/main/n/nodejs/${PACKAGE_FILENAME}" \
    -O "$PACKAGE_PATH";
printf '%s  %s\n' "$NODEJS_DEB_SHA256" "$PACKAGE_PATH" | sha256sum --check --strict -;

chroot "${OUTPUTDIR}" apt-get install -y --no-install-recommends "/tmp/${PACKAGE_FILENAME}";
rm -f "$PACKAGE_PATH";
chroot_deinit;
