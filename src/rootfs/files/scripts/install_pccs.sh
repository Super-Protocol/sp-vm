#!/bin/bash

# bash unofficial strict mode;
set -euo pipefail;

# public, required
# OUTPUTDIR

# private
BUILDROOT="/buildroot";
PCCS_DIRNAME="sgx-dcap-pccs";
PCCS_ORIGINAL_LOCATION="/opt/intel";
PCCS_INSTALL_DIR="/usr/local";

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

function add_intel_sgx_repository() {
    log_info "downloading Intel SGX APT key";
    wget \
        "https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key" \
        -O "${OUTPUTDIR}/tmp/intel-sgx-deb.key";

    log_info "adding Intel SGX repository";
    chroot "${OUTPUTDIR}" /bin/bash -c 'cat /tmp/intel-sgx-deb.key | tee /etc/apt/trusted.gpg.d/intel-sgx-deb.asc > /dev/null && \
        echo "deb [arch=amd64] https://download.01.org/intel-sgx/sgx_repo/ubuntu noble main" > /etc/apt/sources.list.d/intel-sgx.list \
        && apt update';
    
    rm "${OUTPUTDIR}/tmp/intel-sgx-deb.key";
}

function install_pccs_package() {
    log_info "downloading and unpacking PCCS package without postinst configuration";
    # Prevent overwriting /lib symlink by extracting to temp dir and using tar to copy contents
    # Use --dereference on extract to follow symlinks like /lib -> usr/lib
    chroot "${OUTPUTDIR}" /bin/bash -c 'cd /tmp && \
        apt-get download sgx-dcap-pccs && \
        dpkg-deb -x sgx-dcap-pccs*.deb /tmp/pccs-extract && \
        tar -C /tmp/pccs-extract -cf - . | tar -C / --dereference -xf - && \
        rm -rf sgx-dcap-pccs*.deb /tmp/pccs-extract';
    
    log_info "installing PCCS npm dependencies";
    chroot "${OUTPUTDIR}" /bin/bash -c "cd ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME} && npm config set engine-strict true && npm install";
    
    log_info "creating pccs system user";
    chroot "${OUTPUTDIR}" /bin/bash -c "adduser --quiet --system pccs --group --home ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME} --no-create-home --shell /bin/bash";
}

function move_pccs_to_custom_location() {
    log_info "moving PCCS from ${PCCS_ORIGINAL_LOCATION} to ${PCCS_INSTALL_DIR}";
    mkdir -p "$(dirname "${OUTPUTDIR}${PCCS_INSTALL_DIR}")";
    mv "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}" "${OUTPUTDIR}${PCCS_INSTALL_DIR}";
    
    log_info "removing old ${PCCS_ORIGINAL_LOCATION} directory structure";
    rm -rf "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}";
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

function generate_ssl_keys() {
    log_info "generating SSL keys for PCCS";
    mkdir -p "${OUTPUTDIR}${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME}/ssl_key";
    
    chroot "${OUTPUTDIR}" /bin/bash -c "cd ${PCCS_ORIGINAL_LOCATION}/${PCCS_DIRNAME} && \
        openssl genrsa -out ssl_key/private.pem 2048 && \
        openssl req -new -key ssl_key/private.pem -out ssl_key/csr.pem -subj '/CN=localhost' && \
        openssl x509 -req -days 365 -in ssl_key/csr.pem -signkey ssl_key/private.pem -out ssl_key/file.crt";
}

function set_pccs_permissions() {
    log_info "setting PCCS permissions";
    chroot "${OUTPUTDIR}" /bin/bash -c "chown -R pccs:pccs ${PCCS_INSTALL_DIR}/${PCCS_DIRNAME} && chmod -R 750 ${PCCS_INSTALL_DIR}/${PCCS_DIRNAME}";
}

function update_pccs_service() {
    log_info "updating PCCS systemd service with new NodeJs path";
    if [ -f "${OUTPUTDIR}/usr/lib/systemd/system/pccs.service" ]; then
        # Find node binary path
        local NODE_PATH=$(chroot "${OUTPUTDIR}" /bin/bash -c 'which node' 2>/dev/null || true)
        
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
add_intel_sgx_repository;
install_pccs_package;
create_pccs_config;
generate_ssl_keys;
update_pccs_service;
enable_pccs_service;
move_pccs_to_custom_location;
set_pccs_permissions;
chroot_deinit;


