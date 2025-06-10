FROM ubuntu:24.04 AS kernel_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential curl libssl-dev bc elfutils libelf-dev bison flex
ARG kernel_version=6.12.13
ARG kernel_version_major=6

ADD https://cdn.kernel.org/pub/linux/kernel/v${kernel_version_major}.x/linux-${kernel_version}.tar.xz /buildroot/linux-${kernel_version}.tar.xz
RUN curl -Ss --fail https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc | grep linux-${kernel_version}.tar.xz > /buildroot/linux-${kernel_version}.sha256
WORKDIR /buildroot
RUN sha256sum -c linux-${kernel_version}.sha256
RUN tar -xf linux-${kernel_version}.tar.xz
