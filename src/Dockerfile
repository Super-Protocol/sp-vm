# syntax=docker/dockerfile:1-labs

FROM ubuntu:24.04 AS busybox_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
ARG busybox_version=1_36_1
ADD https://github.com/mirror/busybox/archive/refs/tags/${busybox_version}.tar.gz /tmp/busybox-${busybox_version}.tar.gz
RUN tar -C /tmp -xvf/tmp/busybox-${busybox_version}.tar.gz
WORKDIR /tmp/busybox-${busybox_version}
ADD initramfs/files/busybox_config /tmp/busybox-${busybox_version}/.config
RUN make -j
RUN mkdir -p /initramfs-root/sbin
RUN cp /tmp/busybox-${busybox_version}/busybox /initramfs-root/sbin/busybox

FROM ubuntu:24.04 AS util_linux_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
ARG util_linux_version=2.41
ADD https://www.kernel.org/pub/linux/utils/util-linux/v${util_linux_version}/util-linux-${util_linux_version}.tar.gz /tmp/util-linux-${util_linux_version}.tar.gz
RUN tar -C /tmp -xvf/tmp/util-linux-${util_linux_version}.tar.gz
WORKDIR /tmp/util-linux-${util_linux_version}
RUN ./configure --disable-shared --enable-static --disable-liblastlog2 -without-tinfo --without-ncurses --disable-ipv6 --disable-pylibmount
RUN make -j blkid LDFLAGS="--static"
RUN strip blkid
RUN mkdir -p /initramfs-root/sbin
RUN cp /tmp/util-linux-${util_linux_version}/blkid /initramfs-root/sbin/blkid

FROM ubuntu:24.04 AS lvm2_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential git libblkid-dev libaio-dev uuid-dev pkg-config
ARG lvm2_repo=https://github.com/lvmteam/lvm2
ARG lvm2_version=v2_03_16
RUN git clone --depth 1 --branch "${lvm2_version}" "${lvm2_repo}" /tmp/lvm2
WORKDIR /tmp/build-root
RUN /tmp/lvm2/configure --enable-static_link --disable-selinux --prefix /initramfs-root
RUN make -j
RUN make install

FROM ubuntu:24.04 AS cryptsetup_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential git libblkid-dev libaio-dev autoconf automake autopoint libtool gettext libssl-dev zlib1g-dev libseccomp2 libseccomp-dev uuid-dev pkg-config libgcrypt20-dev libpopt-dev libjson-c-dev
COPY --from=lvm2_builder /initramfs-root /initramfs-root
COPY --from=lvm2_builder /tmp/build-root/libdm/libdevmapper.pc /usr/lib/pkgconfig/devmapper.pc
ARG cryptsetup_repo=https://gitlab.com/cryptsetup/cryptsetup
ARG cryptsetup_version=v2.5.0
RUN git clone --depth 1 --branch "${cryptsetup_version}" "${cryptsetup_repo}" /tmp/cryptsetup
WORKDIR /tmp/cryptsetup
RUN /tmp/cryptsetup/autogen.sh
WORKDIR /tmp/build-root
RUN CFLAGS="-I/initramfs-root/include" CXXFLAGS="-I/initramfs-root/include" LDFLAGS="-L/initramfs-root/lib" /tmp/cryptsetup/configure --enable-static --enable-static-cryptsetup --disable-udev --disable-external-tokens --disable-ssh-token --disable-asciidoc --prefix /initramfs-root
RUN make -j
RUN make install
RUN strip /initramfs-root/sbin/veritysetup.static


FROM ubuntu:24.04 AS gen_init_cpio_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential
RUN apt -y install git
RUN git clone --depth 1 --filter=blob:none --sparse https://github.com/torvalds/linux.git /tmp/linux
WORKDIR /tmp/linux
RUN git sparse-checkout add usr
WORKDIR /tmp/linux/usr
RUN make -j gen_init_cpio
RUN install gen_init_cpio /usr/sbin/


FROM gen_init_cpio_builder AS initramfs_builder
COPY --from=busybox_builder /initramfs-root/sbin/busybox /initramfs-root/sbin/
COPY --from=util_linux_builder /initramfs-root/sbin/blkid /initramfs-root/sbin/
COPY --from=cryptsetup_builder /initramfs-root/sbin/veritysetup.static /initramfs-root/sbin/
ADD initramfs/files/initramfs.list /initramfs-root/initramfs.list
ADD initramfs/files/init.sh /initramfs-root/sbin/init.sh
RUN gen_init_cpio /initramfs-root/initramfs.list | gzip -9 -n > /initramfs-root/initramfs.cpio.gz


FROM ubuntu:24.04 AS kernel_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential curl libssl-dev bc elfutils libelf-dev bison flex cpio kmod rsync debhelper
ARG KERNEL_VERSION=6.12.13

WORKDIR /buildroot

ADD kernel/files/scripts/log.sh /buildroot/files/scripts/

ADD kernel/files/scripts/download_and_verify_kernel_src.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/download_and_verify_kernel_src.sh

ADD kernel/files/scripts/merge-configs.sh /buildroot/files/scripts/
ADD kernel/files/scripts/merge_config.sh /buildroot/files/scripts/
ADD kernel/files/configs /buildroot/files/configs
RUN /buildroot/files/scripts/merge-configs.sh

COPY --from=initramfs_builder /initramfs-root/initramfs.cpio.gz /buildroot/files/
ADD kernel/files/scripts/build-kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/build-kernel.sh

FROM ubuntu:noble-20250714 AS rootfs_builder
RUN apt update && apt install -y wget gcc make build-essential debootstrap

ARG PROVIDER_CONFIG_DST=/sp
ARG VERSION_CODENAME=noble
ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

WORKDIR /buildroot

ADD rootfs/files/scripts/log.sh /buildroot/files/scripts/

ADD rootfs/files/scripts/create_base_system.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/create_base_system.sh

RUN mkdir -p "${OUTPUTDIR}/etc/systemd/system/getty.target.wants"
RUN ln -sf "/lib/systemd/system/getty@.service" "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/getty@ttyS0.service"

RUN cp "${OUTPUTDIR}/usr/share/systemd/tmp.mount" "${OUTPUTDIR}/etc/systemd/system/tmp.mount";

ADD rootfs/files/configs/01-netplan.yaml ${OUTPUTDIR}/etc/netplan/
ADD rootfs/files/configs/fstab ${OUTPUTDIR}/etc/
ADD rootfs/files/configs/tdx-attest.conf ${OUTPUTDIR}/etc/
RUN sed -i "1 s|^.*$|AuthorizedKeysFile ${PROVIDER_CONFIG_DST}/authorized_keys|" "${OUTPUTDIR}/etc/ssh/sshd_config"

ADD rootfs/files/configs/chrony/chrony.conf ${OUTPUTDIR}/etc/chrony/
ADD rootfs/files/configs/chrony/chrony.service ${OUTPUTDIR}/lib/systemd/system/

ADD rootfs/files/configs/state_disk_mount/state_disk_mount.service ${OUTPUTDIR}/etc/systemd/system/
ADD rootfs/files/configs/state_disk_mount/state_disk_mount.sh ${OUTPUTDIR}/usr/local/bin/
RUN ln -s /etc/systemd/system/state_disk_mount.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/state_disk_mount.service"

COPY --from=kernel_builder /output/deb ${OUTPUTDIR}/kernel_deb
ADD rootfs/files/scripts/install_kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/install_kernel.sh

ADD rootfs/files/scripts/chroot.sh /buildroot/files/scripts/
ADD rootfs/files/scripts/install_nvidia.sh /buildroot/files/scripts/
#RUN --security=insecure /buildroot/files/scripts/install_nvidia.sh
#RUN sed -i '1 s|^.*$|-:root:ALL|' "${OUTPUTDIR}/etc/security/access.conf"
#RUN sed -i '1 s|^.*$|account required pam_access.so|' "${OUTPUTDIR}/etc/pam.d/login"

# after all!
#ADD files/scripts/cleanup_rootfs.sh /buildroot/files/scripts/
#RUN /buildroot/files/scripts/cleanup_rootfs.sh

# ADD files/scripts/install_nvidia_drivers.sh /buildroot/files/scripts/

# TODO: remove compiler and headers from final image
# rm -rf $rootfs_dir/usr/share/{bash-completion,bug,doc,info,lintian,locale,man,menu,misc,pixmaps,terminfo,zsh}
# cp --remove-destination /etc/resolv.conf "$rootfs_dir/etc"
# cp --remove-destination /etc/ssl/certs/ca-certificates.crt "$dir"
# rm -rf "$rootfs_dir/var/run"
# rm -rf ./var/cache/ ./var/lib ./var/log ./var/tmp


FROM ubuntu:24.04 AS image_builder
ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt -y install qemu-utils grub-pc parted udev fdisk e2fsprogs dosfstools kpartx cryptsetup-bin
RUN apt -y install grub-efi  # this needs to be installed separately!

ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs
ARG VERSION=build-228
ARG KERNEL_VERSION=6.12.13

WORKDIR /output
ADD kernel/files/scripts/log.sh /buildroot/files/scripts/

ADD image/files/scripts/create_image.sh /buildroot/files/scripts/
ADD image/files/configs/grub.cfg.tmpl /buildroot/files/configs/
RUN --mount=type=bind,target=/output/rootfs,readonly,from=rootfs_builder,source=/output/rootfs --security=insecure \
    /buildroot/files/scripts/create_image.sh
