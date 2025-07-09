FROM ubuntu:24.04 AS kernel_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential curl libssl-dev bc elfutils libelf-dev bison flex
ARG KERNEL_VERSION=6.12.13

WORKDIR /buildroot

ADD files/scripts/log.sh /buildroot/files/scripts/

ADD files/scripts/download_and_verify_kernel_src.sh /buildroot/files/scripts/
RUN /buildroot/files/scripts/download_and_verify_kernel_src.sh

ADD files/scripts/merge-configs.sh /buildroot/files/scripts/
ADD files/scripts/merge_config.sh /buildroot/files/scripts/
ADD files/configs /buildroot/files/configs
RUN /buildroot/files/scripts/merge-configs.sh
