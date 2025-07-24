#!/bin/bash

# public, required
# OUTPUTDIR

function check_sourced() {
    if [ ${0##*/} = "chroot.sh" ]; then  # excluding script itself
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

function chroot_init() {
    mount -t sysfs -o ro none "$OUTPUTDIR/sys";
    mount -t proc -o ro none "$OUTPUTDIR/proc";
    mount -t tmpfs none "$OUTPUTDIR/tmp";
    mount --bind /dev "$OUTPUTDIR/dev";
    mount -t devpts none "$OUTPUTDIR/dev/pts";
}
function chroot_deinit() {
    umount "$OUTPUTDIR/sys" || true;
    umount "$OUTPUTDIR/proc" || true;
    umount "$OUTPUTDIR/tmp" || true;
    ummount "$OUTPUTDIR/dev/pts" || true;
    umount "$OUTPUTDIR/dev" || true;
}

if ! check_sourced; then
    show_usage;
    exit 1;
fi

unset -f show_usage;
unset -f check_sourced;
