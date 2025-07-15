#!/bin/bash

function check_sourced() {
    if [ ${0##*/} = "log.sh" ]; then  # excluding script itself
        return 1;
    fi
    case ${0##*/} in dash|-dash|bash|-bash|ksh|-ksh|sh|-sh|*.sh|fbt|ufbt)
        return 0;;
    esac
    return 1;
}

function show_usage() {
    echo "Running this script manually is wrong, please source it";
    echo "Example:";
    printf "\tsource $0\n";
}

function _log() {
    local TYPE="$1";
    local MSG="$2";

    local DATE="$(date +'%Y-%m-%d %H:%M:%S')";

    echo "$DATE: $TYPE: $0: $MSG"
}

function log_fail() {
    _log "FAIL" "$1" >&2;
    return 1;
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

if ! check_sourced; then
    show_usage;
    exit 1;
fi
