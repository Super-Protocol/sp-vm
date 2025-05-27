#!/bin/bash

# shellcheck disable=SC2155,SC2016

set -euo pipefail;

# Defaults
DEFAULT_GITHUB_REPO_URL="https://github.com/Super-Protocol/sp-kata-containers";
DEFAULT_GITHUB_CHECKOUT_TO="sp-main";
DEFAULT_PROVIDER_CONFIG_DST="/sp";
DEFAULT_PREPARE_TO_UPLOAD_RELEASE_TAG="build-0";
DEFAULT_PREPARE_TO_UPLOAD_S3_BUCKET="builds-vm";
DEFAULT_PREPARE_TO_UPLOAD_FILES="rootfs.img OVMF.fd OVMF_AMD.fd root_hash.txt vmlinuz";

# Command line args
GITHUB_REPO_URL="$DEFAULT_GITHUB_REPO_URL";
GITHUB_CHECKOUT_TO="$DEFAULT_GITHUB_CHECKOUT_TO";
PROVIDER_CONFIG_DST="$DEFAULT_PROVIDER_CONFIG_DST";
PREPARE_TO_UPLOAD_RELEASE_TAG="$DEFAULT_PREPARE_TO_UPLOAD_RELEASE_TAG";
PREPARE_TO_UPLOAD_S3_BUCKET="$DEFAULT_PREPARE_TO_UPLOAD_S3_BUCKET";
PREPARE_TO_UPLOAD_FILES="$DEFAULT_PREPARE_TO_UPLOAD_FILES";
SP_CA_CRT="${SP_CA_CRT:-""}";
ALWAYS_CLONE_FLAG="";
SKIP_PULL_FLAG="";
SKIP_REMOVE_BUILD_DIR_FLAG="";

# Private
SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )";
SCRIPT_PATH="$SCRIPT_DIR/$0";
KATA_REPO_DIR="$SCRIPT_DIR/kata-containers";
BUILD_DIR="$KATA_REPO_DIR/build";
ROOTFS_DIR="$BUILD_DIR/rootfs";
LIB_DIR="$SCRIPT_DIR/lib";
KERNEL_NAME="nvidia-gpu-confidential";
DISTRO="ubuntu";
OS_VERSION="noble";
CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb";
ROOTFS_EXTRA_PKGS="init openssh-server netplan.io curl htop open-iscsi cryptsetup ca-certificates gnupg2 kmod";

function export_vars_for_other_scripts() {
    export ROOTFS_DIR;
    export PROVIDER_CONFIG_DST;
    export DISTRO;
    export OS_VERSION;
    export ROOTFS_EXTRA_PKGS;
}

function _log() {
    local TYPE="$1";
    local MSG="$2";

    local DATE="$(date +'%Y-%m-%d %H:%M:%S')";

    echo "$DATE: $TYPE: $MSG"
}

function log_err() {
    _log "ERROR" "$1" >&2;
}
function log_warn() {
    _log "WARNING" "$1";
}
function log_info() {
    _log "INFO" "$1";
}

function show_usage() {
    echo "usage";
    local MATCHER_START="parse_args_start_block";
    local MATCHER_END="parse_args_end_block";
    awk '/'"$MATCHER_START"'/{flag=1; next} /'"$MATCHER_END"'/{flag=0} flag' "$SCRIPT_PATH";
}

function check_arg_value() {
    local ARG="$1";
    local VALUE="$2";
    if [[ "$VALUE" == -* ]]; then
        log_err "Arg $ARG requires a value, got another arg $VALUE";
        exit 1;
    fi
    if [[ -z "$VALUE" ]]; then
        log_err "Arg $ARG requires a value";
        exit 1;
    fi
}

function check_default_arg_value() {
    local ARG="$1";
    local VALUE="$2";
    local DEFAULT_VALUE="$3";

    if [[ "$VALUE" == "$DEFAULT_VALUE" ]]; then
        log_warn "Using default $ARG with value $VALUE";
    fi
}

function warn_about_defaults() {
    check_default_arg_value "GITHUB_REPO_URL" "$GITHUB_REPO_URL" "$DEFAULT_GITHUB_REPO_URL";
    check_default_arg_value "GITHUB_CHECKOUT_TO" "$GITHUB_CHECKOUT_TO" "$DEFAULT_GITHUB_CHECKOUT_TO";
    check_default_arg_value "PROVIDER_CONFIG_DST" "$PROVIDER_CONFIG_DST" "$DEFAULT_PROVIDER_CONFIG_DST";
    check_default_arg_value "PREPARE_TO_UPLOAD_RELEASE_TAG" "$PREPARE_TO_UPLOAD_RELEASE_TAG" "$DEFAULT_PREPARE_TO_UPLOAD_RELEASE_TAG";
    check_default_arg_value "PREPARE_TO_UPLOAD_S3_BUCKET" "$PREPARE_TO_UPLOAD_S3_BUCKET" "$DEFAULT_PREPARE_TO_UPLOAD_S3_BUCKET";
    check_default_arg_value "PREPARE_TO_UPLOAD_FILES" "$PREPARE_TO_UPLOAD_FILES" "$DEFAULT_PREPARE_TO_UPLOAD_FILES";
}

function check_git() {
    git --version >/dev/null 2>&1 || {
        log_err "Please install git first!";
        exit 2;
    }
}

function update_submodules() {
    log_info "Udating submodules";
    git submodule update --init;
}

function git_clone_repo() {
    if [[ -d "$KATA_REPO_DIR" ]]; then
        if [[ -n "$ALWAYS_CLONE_FLAG" ]]; then
            log_warn "Dir $KATA_REPO_DIR is already exists, cleaning up, because --always-clone flag is set";
            rm -rf "$KATA_REPO_DIR";
        else
            log_info "Dir $KATA_REPO_DIR is already exists, clone skipped, set --always-clone flag to clone again";
            return;
        fi
    fi
    git clone "$GITHUB_REPO_URL" "$KATA_REPO_DIR";
}

function git_checkout_to_ref() {
    log_info "Switching to $GITHUB_CHECKOUT_TO";
    pushd "$KATA_REPO_DIR" >/dev/null;

    git checkout "$GITHUB_CHECKOUT_TO";

    if [[ -n "$SKIP_PULL_FLAG" ]]; then
        log_warn "Skipping pull recent changes because --no-pull flag is set";
        return;
    fi
    log_info "Pulling recent changes, set --no-pull flag to skip";
    git pull;

    popd >/dev/null;
}

function create_build_dir() {
    if [[ -d "$BUILD_DIR" ]]; then
        if [[ -z "$SKIP_REMOVE_BUILD_DIR_FLAG" ]]; then
            log_warn "Dir $BUILD_DIR is already exists, cleaning up, set --no-remove-build-dir flag to skip";
            rm -rf "$BUILD_DIR";
        else
            log_info "Dir $BUILD_DIR is already exists, skipping clean up because --no-remove-build-dir flag is set";
            return;
        fi
    fi
    mkdir "$BUILD_DIR";
}

# TODO: move to full docker build..
function build_kernel() {
    log_info "Building kernel";
    pushd "$KATA_REPO_DIR/tools/packaging/kata-deploy/local-build" >/dev/null;

    ./kata-deploy-binaries-in-docker.sh \
        "--build=kernel-$KERNEL_NAME";

    popd >/dev/null;
}

function add_deb_to_rootfs() {
    log_info "Adding kata debs to rootfs dir";

    mkdir -p "$BUILD_DIR/rootfs/opt/deb";
    mkdir -p "$BUILD_DIR/rootfs/opt/deb/nvidia";

    find "$KATA_REPO_DIR/tools/packaging/kata-deploy/local-build/build/kernel-$KERNEL_NAME/builddir/" \
        -name "*.deb" \
        -exec cp {} "$BUILD_DIR/rootfs/opt/deb/" \;;
    wget -P "$BUILD_DIR/rootfs/opt/deb/nvidia" "$CUDA_KEYRING_URL";
}

function prepare_superprotocol_certs() {
    log_info "Building ca initializer";
    local CERT_FOLDER="$KATA_REPO_DIR/tools/osbuilder/rootfs-builder/ubuntu/superprotocol/cert";
    echo "$SP_CA_CRT" > "$CERT_FOLDER/superprotocol-ca.crt";

    SUPER_REGISTRY_HOST="registry.superprotocol.local";
    
    # Create CA cert
    openssl genrsa -out ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.ca.key 2048
    openssl req -x509 -new -nodes -key ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.ca.key -sha256 -days 3650 -out ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.ca.crt -subj "/ST=Milk Galaxy/L=Planet Earth/O=SuperProtocol/OU=MyUnit/CN=SuperProtocol.com"

    # Create registry cert
    openssl genrsa -out ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.key 2048
    printf "[req]\ndefault_bits = 2048\nprompt = no\ndistinguished_name = req_distinguished_name\nreq_extensions = req_ext\n[req_distinguished_name]\nC = US\nST = Milk Galaxy\nL = Planet Earth\nO = SuperProtocol\nOU = MyUnit\nCN = ${SUPER_REGISTRY_HOST}\n[req_ext]\nsubjectAltName = @alt_names\n[alt_names]\nDNS.1 = ${SUPER_REGISTRY_HOST}\n[v3_ext]\nsubjectAltName = @alt_names\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment\n" > ${CERT_FOLDER}/san.cnf
    openssl req -new -key ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.key -out ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.csr -config ${CERT_FOLDER}/san.cnf
    openssl x509 -req -in ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.csr -CA ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.ca.crt -CAkey ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.ca.key -CAcreateserial -out ${CERT_FOLDER}/${SUPER_REGISTRY_HOST}.crt -days 3650 -sha256 -extfile ${CERT_FOLDER}/san.cnf -extensions v3_ext

}

function build_rootfs() {
    log_info "Building rootfs";
    pushd "$KATA_REPO_DIR/tools/osbuilder/rootfs-builder" >/dev/null;

    script -fec 'sudo -E \
        USE_DOCKER=true \
        PROVIDER_CONFIG_DST="$PROVIDER_CONFIG_DST" \
        CONFIDENTIAL_GUEST=yes \
        MEASURED_ROOTFS=yes \
        EXTRA_PKGS="$ROOTFS_EXTRA_PKGS" \
        ./rootfs.sh "$DISTRO"';

    popd >/dev/null;
}

function build_image() {
    log_info "Building image";
    pushd "$KATA_REPO_DIR/tools/osbuilder/image-builder" >/dev/null;

    script -fec 'sudo -E \
        USE_DOCKER=true \
        MEASURED_ROOTFS=yes \
        ./image_builder.sh \
        "$ROOTFS_DIR"';

    popd >/dev/null;
}

function copy_artifacts() {
    log_info "Copying artifacts";
    cp "$KATA_REPO_DIR/tools/osbuilder/image-builder/kata-containers.img" "$BUILD_DIR/rootfs.img";
    cp "$KATA_REPO_DIR/tools/osbuilder/image-builder/root_hash.txt" "$BUILD_DIR/";
    cp -L "$KATA_REPO_DIR/tools/packaging/kata-deploy/local-build/build/kernel-$KERNEL_NAME/destdir/opt/kata/share/kata-containers/vmlinuz-$KERNEL_NAME.container" "$BUILD_DIR/vmlinuz";
    cp "$KATA_REPO_DIR/tools/osbuilder/rootfs-builder/ubuntu/superprotocol"/{OVMF.fd,OVMF_AMD.fd} "$KATA_REPO_DIR/build";
}

function calc_hashes() {
    log_info "Calculating file hashes to file $BUILD_DIR/vm.json";
    local KEY;
    local FILE;
    local FILES;
    local SHA256;
    local JSON="{\n";
    IFS=' ' read -r -a FILES <<< "$PREPARE_TO_UPLOAD_FILES";
    for FILE in "${FILES[@]}"; do
        if [ -f "$BUILD_DIR/$FILE" ]; then
            KEY="$FILE";
            case "$FILE" in
                rootfs.img) KEY="rootfs" ;;
                OVMF.fd) KEY="bios" ;;
                OVMF_AMD.fd) KEY="bios_amd" ;;
                root_hash.txt) KEY="root_hash" ;;
                vmlinuz) KEY="kernel" ;;
                *)
                    log_err "Don't know how to indentify file: $FILE";
                    exit 2;
                    ;;
            esac

            SHA256=$(sha256sum "$BUILD_DIR/$FILE" | awk '{print $1}');
            JSON+="  \"$KEY\": {\n";
            JSON+="    \"bucket\": \"$PREPARE_TO_UPLOAD_S3_BUCKET\",\n";
            JSON+="    \"prefix\": \"$PREPARE_TO_UPLOAD_RELEASE_TAG\",\n";
            JSON+="    \"filename\": \"$FILE\",\n";
            JSON+="    \"sha256\": \"$SHA256\"\n";
            JSON+="  },\n";
        else
            echo "File ${BUILD_DIR}/${FILE} not found";
            exit 1;
        fi
    done

    JSON="${JSON%,*}";
    JSON+="\n}";
    echo -e "$JSON" > "$BUILD_DIR/vm.json";

    log_info "Calculation done, hashes: $(cat "$BUILD_DIR/vm.json")";
}

function check_required_args() {
    if [[ -z "$SP_CA_CRT" ]]; then
        log_err "SP_CA_CRT is empty! Use SP_CA_CRT with the cert data or pass --sp-ca-crt-file arg with the path to the crt file";
        exit 2;
    fi
}

# Warning! Take care of the format of this block!
# The lines below used in show_usage function for
# dinamically help templating
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in # parse_args_start_block
            --github-repo)
                check_arg_value "$1" "$2";
                GITHUB_REPO_URL="$2";
                shift 2;
                ;;
            --prepare-to-upload-release-tag)
                check_arg_value "$1" "$2";
                PREPARE_TO_UPLOAD_RELEASE_TAG="$2";
                shift 2;
                ;;
            --prepare-to-upload-files)
                check_arg_value "$1" "$2";
                PREPARE_TO_UPLOAD_FILES="$2";
                shift 2;
                ;;
            --prepare-to-upload-s3-bucket)
                check_arg_value "$1" "$2";
                PREPARE_TO_UPLOAD_S3_BUCKET="$2";
                shift 2;
                ;;
            --checkout-to)
                check_arg_value "$1" "$2";
                GITHUB_CHECKOUT_TO="$2";
                shift 2;
                ;;
            --provider-config-dst)
                check_arg_value "$1" "$2";
                PROVIDER_CONFIG_DST="$2";
                shift 2;
                ;;
            --sp-ca-crt-file)
                check_arg_value "$1" "$2";
                SP_CA_CRT="$(cat "$2")";
                shift 2;
                ;;
            --always-clone)
                ALWAYS_CLONE_FLAG="true";
                shift 1;
                ;;
            --no-remove-build-dir)
                SKIP_REMOVE_BUILD_DIR_FLAG="true";
                shift 1;
                ;;
            --no-pull)
                SKIP_PULL_FLAG="true";
                shift 1;
                ;;
            -h|--help)
                show_usage;
                exit 0;
                ;;
            -*)
                log_err "Invalid option: $1";
                exit 1;
                ;;
            *)
                log_err "Invalid positional arg: $1";
                exit 1;
                ;;
        esac # parse_args_end_block
    done
    warn_about_defaults;
    check_required_args;
    export_vars_for_other_scripts;
}

function main() {
    # Prepare
    check_git;
    update_submodules;
    git_clone_repo;
    git_checkout_to_ref;
    create_build_dir;

    # Build part
    prepare_superprotocol_certs;
    build_kernel;
    add_deb_to_rootfs;
    build_rootfs;
    build_image;

    # Packaging
    copy_artifacts;
    calc_hashes;
}

parse_args "$@";
main;
