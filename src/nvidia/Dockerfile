FROM ubuntu:24.04 AS nvidia_builder
RUN apt-get update && apt-get install -y wget gcc make build-essential git pipx python3 python3-pip

RUN python3 -m pip install pyinstaller --break-system-packages

ARG OUTPUTROOT=/output
ARG OUTPUTDIR=${OUTPUTROOT}/rootfs

WORKDIR /buildroot

WORKDIR /buildroot/nvidia_gpu_tools
RUN git clone https://github.com/NVIDIA/gpu-admin-tools
RUN /usr/local/bin/pyinstaller -s -F gpu-admin-tools/nvidia_gpu_tools.py
# add ./dist/nvidia_gpu_tools to rootfs bin

RUN apt install -y curl gpg ca-certificates
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
RUN curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
RUN apt update

RUN apt install -y make gcc gawk kmod libvulkan1 pciutils jq zstd linuxptp
