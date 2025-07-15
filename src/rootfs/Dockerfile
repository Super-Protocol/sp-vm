FROM ubuntu:24.04 AS rootfs_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential debootstrap

ARG PROVIDER_CONFIG_DST=/sp
ARG VERSION_CODENAME=noble
ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

WORKDIR /buildroot

ADD files/scripts/log.sh /buildroot/files/scripts/

ADD files/scripts/create_base_system.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/create_base_system.sh

ADD files/configs/01-netplan.yaml ${OUTPUTDIR}/etc/netplan/
ADD files/configs/fstab ${OUTPUTDIR}/etc/
ADD files/configs/tdx-attest.conf ${OUTPUTDIR}/etc/
ADD files/configs/state_disk_mount/state_disk_mount.service ${OUTPUTDIR}/etc/systemd/system/
ADD files/configs/state_disk_mount/state_disk_mount.sh ${OUTPUTDIR}/usr/local/bin/
RUN sed -i "1 s|^.*$|AuthorizedKeysFile ${PROVIDER_CONFIG_DST}/authorized_keys|" "${OUTPUTDIR}/etc/ssh/sshd_config"

#ADD files/scripts/create_base_system.sh /buildroot/files/scripts/
#RUN /buildroot/files/scripts/create_base_system.sh

# TODO: remove compiler and headers from final image
# rm -rf $rootfs_dir/usr/share/{bash-completion,bug,doc,info,lintian,locale,man,menu,misc,pixmaps,terminfo,zsh}
# cp --remove-destination /etc/resolv.conf "$rootfs_dir/etc"
# cp --remove-destination /etc/ssl/certs/ca-certificates.crt "$dir"
# rm -rf "$rootfs_dir/var/run"

