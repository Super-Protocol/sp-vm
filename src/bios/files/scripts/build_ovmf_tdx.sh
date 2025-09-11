#!/bin/bash

# private, part1
BUILDROOT="/buildroot";
SRCDIR="$BUILDROOT/edk2_build";

# edk2 build tools, this script will fail with strict mode..
source "$SRCDIR/edksetup.sh";

# bash unofficial strict mode;
set -euo pipefail;

# init loggggging;
source "$BUILDROOT/files/scripts/log.sh";

# build variables
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
PCD_RELEASE_DATE=$(date -d@"$SOURCE_DATE_EPOCH" "+%m/%d/%Y")
EDK2_TOOLCHAIN="GCC5"
EDK2_BUILD_ARCH="X64"

export PYTHON3_ENABLE=TRUE

function build_tdx_ovmf() {
    log_info "building tdx ovmf";
    pushd "$SRCDIR";
    rm -rf "Build/OvmfX64";
    PYTHON3_ENABLE=TRUE \
        build -a \
            ${EDK2_BUILD_ARCH} \
            -t ${EDK2_TOOLCHAIN} \
            -p OvmfPkg/OvmfPkgX64.dsc \
            -DCC_MEASUREMENT_ENABLE=TRUE \
            -DNETWORK_HTTP_BOOT_ENABLE=TRUE \
            -DNETWORK_IP6_ENABLE=TRUE \
            -DNETWORK_TLS_ENABLE \
            -DTPM2_ENABLE=TRUE \
            -DFD_SIZE_4MB \
            -b RELEASE \
            --pcd "PcdFirmwareVendor=L$(lsb_release -is) distribution of EDK II" \
            --pcd "PcdFirmwareVersionString=L2024.02-3+tdx1.0-sp-1" \
            --pcd "PcdFirmwareReleaseDateString=L${PCD_RELEASE_DATE}";
    popd;
}

build_tdx_ovmf;
