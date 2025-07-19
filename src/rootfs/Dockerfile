# syntax=docker/dockerfile:1-labs
FROM ubuntu:noble-20250714 AS rootfs_builder
RUN apt update && apt install -y wget gcc make build-essential debootstrap

ARG PROVIDER_CONFIG_DST=/sp
ARG VERSION_CODENAME=noble
ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

WORKDIR /buildroot

ADD files/scripts/log.sh /buildroot/files/scripts/

ADD files/scripts/create_base_system.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/create_base_system.sh

RUN mkdir -p "${OUTPUTDIR}/etc/systemd/system/getty.target.wants"
RUN ln -sf "/lib/systemd/system/getty@.service" "${OUTPUTDIR}/etc/systemd/system/getty.target.wants/getty@ttyS0.service"

RUN cp "${OUTPUTDIR}/usr/share/systemd/tmp.mount" "${OUTPUTDIR}/etc/systemd/system/tmp.mount";

ADD files/configs/01-netplan.yaml ${OUTPUTDIR}/etc/netplan/
ADD files/configs/fstab ${OUTPUTDIR}/etc/
ADD files/configs/tdx-attest.conf ${OUTPUTDIR}/etc/
RUN sed -i "1 s|^.*$|AuthorizedKeysFile ${PROVIDER_CONFIG_DST}/authorized_keys|" "${OUTPUTDIR}/etc/ssh/sshd_config"

ADD files/configs/chrony/chrony.conf ${OUTPUTDIR}/etc/chrony/
ADD files/configs/chrony/chrony.service ${OUTPUTDIR}/lib/systemd/system/

ADD files/configs/state_disk_mount/state_disk_mount.service ${OUTPUTDIR}/etc/systemd/system/
ADD files/configs/state_disk_mount/state_disk_mount.sh ${OUTPUTDIR}/usr/local/bin/
RUN ln -s /etc/systemd/system/state_disk_mount.service "${OUTPUTDIR}/etc/systemd/system/multi-user.target.wants/state_disk_mount.service"

COPY --from=kernel_builder /output/deb ${OUTPUTDIR}/kernel_deb
ADD files/scripts/install_kernel.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/install_kernel.sh

RUN apt install -y wget curl

ADD files/scripts/chroot.sh /buildroot/files/scripts/
ADD files/scripts/install_nvidia.sh /buildroot/files/scripts/
RUN --security=insecure /buildroot/files/scripts/install_nvidia.sh

#RUN --mount=type=bind,source=.,target=/tmp/test,readonly bash -c 'find /tmp/test > /hmm.txt'


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

