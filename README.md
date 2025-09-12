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
- S3_BUCKET - only for `vm.json`, default `local`

Example:
```bash
docker buildx build -t sp-vm --allow security.insecure src --output type=local,dest=./out --build-arg SP_VM_IMAGE_VERSION=build-0 --build-arg S3_BUCKET=test
```

The build artifacts will be located in the $(pwd)/out directory.

## Local PKI image for build

For local builds you need the PKI service image (tee-pki). Download the tar image from GitHub Container Registry and place it in the repository at:

```
src/rootfs/files/configs/pki-service/pki-authority.tar
```

Use `docker pull ghcr.io/super-protocol/tee-pki-authority-service-lxc:<TAG>` and then
`docker save -o src/rootfs/files/configs/pki-service/pki-authority.tar ghcr.io/super-protocol/tee-pki-authority-service-lxc:<TAG>`.

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

