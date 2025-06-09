FROM debian:12 AS image-builder

RUN DEBIAN_FRONTEND=noninteractive apt update

RUN DEBIAN_FRONTEND=noninteractive apt -y install qemu-utils grub-pc parted udev fdisk e2fsprogs dosfstools kpartx
RUN DEBIAN_FRONTEND=noninteractive apt -y install grub-efi  # this needs to be installed separately!

COPY build.sh /img/

WORKDIR /img
