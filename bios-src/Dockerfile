FROM ubuntu:24.04 AS ovmf_builder_base
RUN apt update && apt install -y wget gcc make build-essential git uuid-dev python-is-python3 nasm iasl

WORKDIR /buildroot

ADD files/configs/gitconfig /root/.gitconfig

RUN git clone --single-branch --depth 1 --branch edk2-stable202411 https://github.com/tianocore/edk2.git ovmf
WORKDIR /buildroot/ovmf
RUN git fetch origin 8b87eb9dfba054331ed16204f36c4885aefc3c94
RUN git checkout -b fix-build edk2-stable202411
RUN git cherry-pick 8b87eb9dfba054331ed16204f36c4885aefc3c94
RUN git submodule update --init --recursive

RUN make -C BaseTools

FROM ovmf_builder_base AS ovmf_builder_sev
ADD files/configs/target_amd_sev.txt /buildroot/ovmf/Conf/target.txt
RUN touch OvmfPkg/AmdSev/Grub/grub.efi
RUN bash -c 'source /buildroot/ovmf/edksetup.sh && build clean'
RUN bash -c 'source /buildroot/ovmf/edksetup.sh && build'
RUN test -f Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd

FROM ovmf_builder_base AS ovmf_builder_tdx
ADD files/configs/target_amd_sev.txt /buildroot/ovmf/Conf/target.txt
RUN touch OvmfPkg/AmdSev/Grub/grub.efi
RUN bash -c 'source /buildroot/ovmf/edksetup.sh && build clean'
RUN bash -c 'source /buildroot/ovmf/edksetup.sh && build'
RUN test -f Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd

#FROM scratch AS sp-ovmf
#COPY --from=ovmf_builder_sev /buildroot/ovmf/Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd /OVMF_AMD.fd
#COPY --from=ovmf_builder_tdx /buildroot/ovmf/Build/AmdSev/RELEASE_GCC5/FV/OVMF.fd /OVMF.fd
