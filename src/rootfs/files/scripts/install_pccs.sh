#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
PCCS_DIRNAME="sgx-dcap-pccs";
PCCS_ORIGINAL_LOCATION="/opt/intel";
INTEL_SGX_REPOSITORY="https://download.01.org/intel-sgx/sgx_repo/ubuntu";

# action|package|version|architecture|repository path|SHA-256
INTEL_SGX_PACKAGES=(
    "install|libsgx-dcap-default-qpl|1.26.100.1-noble1|amd64|pool/main/libs/libsgx-dcap-default-qpl/libsgx-dcap-default-qpl_1.26.100.1-noble1_amd64.deb|84f2c74c8f55fee13841d4ce2cc0fe2c40e9bd5cfb1498f0cc266194cc89ac0a"
    "extract|sgx-dcap-pccs|1.26.100.1-noble1|all|pool/main/web/sgx-dcap-pccs/sgx-dcap-pccs_1.26.100.1-noble1_all.deb|bd07dfc9cb9d1565d3293ef4699b18d3a8f55d913dde9d7a5ff831f8166e88e1"
);
INTEL_SGX_INSTALL_PATHS=();
INTEL_SGX_DOWNLOADED_PATHS=();
PCCS_PACKAGE_PATH="";

# Configuration variables
PCCS_API_KEY="aecd5ebb682346028d60c36131eb2d92"
PCCS_PORT="8081"
PCCS_PASSWORD="pccspassword123"
# Generate SHA512 hash of the password
USER_TOKEN=$(echo -n "${PCCS_PASSWORD}" | sha512sum | awk '{print $1}')

# init loggggging;
source "${BUILDROOT}/files/scripts/log.sh";

# chroot functions
source "${BUILDROOT}/files/scripts/chroot.sh";

function download_intel_sgx_packages() {
    local package_spec action package version architecture repository_path sha256;
    local filename chroot_path host_path;

    for package_spec in "${INTEL_SGX_PACKAGES[@]}"; do
        IFS='|' read -r action package version architecture repository_path sha256 \
            <<< "$package_spec";
        filename="${repository_path##*/}";
        chroot_path="/tmp/${filename}";
        host_path="${OUTPUTDIR}${chroot_path}";

        log_info "downloading ${package}=${version} (${architecture}, ${action})";
        wget "${INTEL_SGX_REPOSITORY}/${repository_path}" \
            -O "$host_path";
        printf '%s  %s\n' "$sha256" "$host_path" \
            | sha256sum --check --strict -;

        INTEL_SGX_DOWNLOADED_PATHS+=("$host_path");
        case "$action" in
            install) INTEL_SGX_INSTALL_PATHS+=("$chroot_path") ;;
            extract) PCCS_PACKAGE_PATH="$chroot_path" ;;
            *) log_fail "unsupported Intel SGX package action: ${action}" ;;
        esac
    done
}

function install_intel_sgx_packages() {
    log_info "installing pinned Intel SGX packages";
    chroot "${OUTPUTDIR}" apt-get install -y --no-install-recommends \
        "${INTEL_SGX_INSTALL_PATHS[@]}";

    log_info "backing up original sgx_default_qcnl.conf";
    cp "${OUTPUTDIR}/etc/sgx_default_qcnl.conf" "${OUTPUTDIR}/etc/sgx_default_qcnl.conf.bak";
}

function install_pccs_package() {
    log_info "unpacking PCCS package without postinst configuration";
    # Prevent overwriting /lib symlink by extracting to temp dir and using tar to copy contents
    # Use --dereference on extract to follow symlinks like /lib -> usr/lib
    # shellcheck disable=SC2016
    chroot "${OUTPUTDIR}" /bin/bash -c 'rm -rf /tmp/pccs-extract && \
        dpkg-deb -x "$1" /tmp/pccs-extract && \
        tar -C /tmp/pccs-extract -cf - . | tar -C / --dereference -xf - && \
        rm -rf /tmp/pccs-extract' _ "$PCCS_PACKAGE_PATH";
    
    log_info "installing PCCS npm dependencies";
    chroot "${OUTPUTDIR}" /bin/bash -c "cd ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME} && npm config set engine-strict true && npm install";
    
    log_info "creating pccs system user";
    chroot "${OUTPUTDIR}" /bin/bash -c "adduser --quiet --system pccs --group --home ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME} --no-create-home --shell /bin/bash";
}

function create_pccs_config() {
    log_info "creating PCCS configuration directory";
    mkdir -p "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/config/";

    log_info "creating PCCS configuration file";
    cat > "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/config/default.json" << EOL
{
    "HTTPS_PORT" : ${PCCS_PORT},
    "hosts" : "127.0.0.1",
    "uri": "https://api.trustedservices.intel.com/sgx/certification/v4/",
    "ApiKey" : "${PCCS_API_KEY}",
    "proxy" : "",
    "RefreshSchedule": "0 0 1 * *",
    "UserTokenHash" : "${USER_TOKEN}",
    "AdminTokenHash" : "${USER_TOKEN}",
    "CachingFillMode" : "LAZY",
    "LogLevel" : "debug",
    "DB_CONFIG" : "sqlite",
    "sqlite" : {
        "database" : "database",
        "username" : "username",
        "password" : "password",
        "options" : {
            "host": "localhost",
            "dialect": "sqlite",
            "pool": {
                "max": 5,
                "min": 0,
                "acquire": 30000,
                "idle": 10000
            },
            "define": {
                "freezeTableName": true
            },
            "logging" : false, 
            "storage": "pckcache.db"
        }
    }
}
EOL
}

function prepare_ssl_key_directory() {
    log_info "preparing an empty PCCS SSL key directory";
    rm -f \
        "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/ssl_key/private.pem" \
        "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/ssl_key/csr.pem" \
        "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/ssl_key/file.crt";
    chroot "${OUTPUTDIR}" install -d -o pccs -g pccs -m 0750 \
        "${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/ssl_key";
}

function set_pccs_permissions() {
    log_info "setting PCCS permissions";
    chroot "${OUTPUTDIR}" /bin/bash -c "chown -R pccs:pccs ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME} && chmod -R 750 ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}";
}

function update_pccs_service() {
    log_info "updating PCCS systemd service with new NodeJs path";
    if [ -f "${OUTPUTDIR}/usr/lib/systemd/system/pccs.service" ]; then
        # Find node binary path
        local NODE_PATH;
        NODE_PATH=$(chroot "${OUTPUTDIR}" /bin/bash -c 'which node' 2>/dev/null || true)
        
        if [ -z "${NODE_PATH}" ]; then
            log_fail "Node.js binary not found in system PATH";
            return 1;
        fi
        
        log_info "found node at ${NODE_PATH}";
        
        # Update paths in service file
        sed -i "s|/usr/bin/node|${NODE_PATH}|g" "${OUTPUTDIR}/usr/lib/systemd/system/pccs.service";
    else
        log_fail "PCCS systemd service file not found at ${OUTPUTDIR}/usr/lib/systemd/system/pccs.service";
        return 1;
    fi
}

function enable_pccs_service() {
    log_info "enabling PCCS service";
    ln -sf /usr/lib/systemd/system/pccs.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/pccs.service";
}

chroot_init;
download_intel_sgx_packages;
install_intel_sgx_packages;
install_pccs_package;
create_pccs_config;
prepare_ssl_key_directory;
update_pccs_service;
enable_pccs_service;
set_pccs_permissions;
rm -f "${INTEL_SGX_DOWNLOADED_PATHS[@]}";
chroot_deinit;
