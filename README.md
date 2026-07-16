# sp-vm

## Overview
The Super Protocol confidential virtual machine image.

## Build
To make possible use `mount`, `losetup`, etc. inside chroot during the Docker build process we need to create an appropriate builder:
```bash
docker buildx create --use --name insecure-builder --buildkitd-flags '--allow-insecure-entitlement security.insecure'
docker buildx build -t sp-vm --allow security.insecure src --output type=local,dest=./out
```

You can pass optional build arguments via docker `--build-arg`, list:
- SP_VM_IMAGE_VERSION - build tag
- SP_VM_BUILD_TYPE - `debug` or `release`, default `debug`; writes `/etc/swarm/swarm-network-type` as `untrusted` for `debug` and `trusted` for `release`
- S3_BUCKET - only for `vm.json`, default `local`

Example:
```bash
docker buildx build -t sp-vm --allow security.insecure src --output type=local,dest=./out --build-arg SP_VM_IMAGE_VERSION=build-0 --build-arg SP_VM_BUILD_TYPE=debug --build-arg S3_BUCKET=test
```

The build artifacts will be located in the $(pwd)/out directory.

## Low-level components

The kernel packages, the kernel image, and the three OVMF images are built
separately from the main VM image:

```bash
docker buildx build \
  --file src/Dockerfile.low-level \
  --target low_level_export \
  --output type=local,dest=./low-level-out \
  src

(cd low-level-out && sha256sum --check SHA256SUMS)
```

The `Build low-level components` workflow publishes the complete output as an
Actions artifact and as individual assets of a prerelease named
`sp-vm-low-level-v<github.run_number>`. The main Dockerfile pins both a release
and the SHA-256 of its `SHA256SUMS`. To use another published release, override
both values together:

```bash
docker buildx build \
  --allow security.insecure \
  --build-arg LOW_LEVEL_RELEASE=sp-vm-low-level-v42 \
  --build-arg LOW_LEVEL_SHA256SUMS=<sha256-of-SHA256SUMS> \
  src \
  --output type=local,dest=./out
```

For local development, replace the release stage with a named BuildKit context:

```bash
docker buildx build \
  --build-context low_level_assets="$(realpath ./low-level-out)" \
  --allow security.insecure \
  src \
  --output type=local,dest=./out
```

The local directory must be flat and contain `vmlinuz`, `OVMF.fd`,
`OVMF_AMD.fd`, `OVMF_TDX.fd`, and at least one `linux-image*.deb`. It normally
also contains the other kernel DEBs. `SHA256SUMS` is optional in local mode and
is not used to validate local files; the common stage still validates the
required layout. The `build-sp-vm` workflow supports release overrides through
the paired `low-level-release` and `low-level-sha256sums` inputs, but does not
accept a local directory.

## Base rootfs reproducibility test

The Ubuntu Noble base rootfs is built from the pinned `20260714T000000Z`
snapshot, including the release, updates, and security pockets. To build it
three times without BuildKit cache and compare canonical rootfs archives:

```bash
src/rootfs/tests/check_base_reproducibility.sh
```

The test requires Docker Buildx and network access to
`snapshot.ubuntu.com`. Set `KEEP_ROOTFS_REPRO_OUTPUT=1` to retain successful
build artifacts for inspection. `ROOTFS_REPRO_RUNS` can change the number of
runs, but must be at least two.

## Local Build - PKI Image Access

For successful local builds, you need permission to pull the image from the repository https://github.com/Super-Protocol/tee-pki/pkgs/container/tee-pki-authority-service-lxc . This may require running `docker login ghcr.io` and an access token.

## Test Run
The `start_superprotocol.sh` script will require changes in the future, but for now, you can test the VM using the following steps:

### Create State Disk
```bash
qemu-img create -f qcow2 state.qcow2 500G;
```

### Create Provider Config Disk
```bash
dd if=/dev/zero of=provider.img bs=1M count=1;
mkfs.ext4 -O ^has_journal,^huge_file,^meta_bg,^ext_attr -L provider_config provider.img;
DEVICE="$(losetup --find --show --partscan provider.img)";
mount "$DEVICE" /mnt;
cp -r profconf/* /mnt/;
rm -rf /mnt/lost+found;
umount /mnt;
losetup -d "$DEVICE";
```

### Run VM
```bash
/usr/bin/qemu-system-x86_64 \
    -enable-kvm \
    -smp cores=10 \
    -m 30G \
    -cpu host,-kvm-steal-time,pmu=off \
    -machine q35,kernel_irqchip=split \
    -device virtio-net-pci,netdev=nic_id0,mac=52:54:00:12:34:56 \
    -netdev user,id=nic_id0 \
    -nographic \
    -vga none \
    -nodefaults \
    -serial stdio \
    -device vhost-vsock-pci,guest-cid=4 \
    -fw_cfg name=opt/ovmf/X-PciMmio64,string=262144 \
    -drive file=sp_build-228.img,if=virtio,format=raw \
    -drive file=state.qcow2,if=virtio,format=qcow2 \
    -drive file=provider.img,if=virtio,format=raw;
```

## References
Some parts of the code, including [kernel configs](src/kernel/files/configs/fragments), were taken from or inspired by [Kata Containers](https://github.com/kata-containers/kata-containers), which is distributed under the [Apache-2.0 license](https://github.com/kata-containers/kata-containers/blob/main/LICENSE).
