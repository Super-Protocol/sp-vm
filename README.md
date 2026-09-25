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
required layout. The `build-sp-vm` workflow always uses the release and
manifest checksum pinned in the main Dockerfile; overrides and local directories
are supported only by local CLI builds. After changing kernel fragments or other
low-level inputs, run the `Build low-level components` workflow and pin the new
release in the main Dockerfile.

## Logical rootfs reproducibility test

The complete logical rootfs is exported after package installation and final
cleanup, before creating any ext4 image. The Ubuntu base uses the pinned
`20260714T000000Z` snapshot, including the release, updates, and security
pockets. To build the full rootfs three times without BuildKit cache and compare
canonical rootfs archives:

```bash
src/rootfs/tests/check_rootfs_reproducibility.sh
```

The test requires Docker Buildx, the `security.insecure` entitlement, and network
access to all package sources used by the rootfs. It does not run `mkfs.ext4`.
Set `KEEP_ROOTFS_REPRO_OUTPUT=1` to retain successful build artifacts for
inspection. `ROOTFS_REPRO_RUNS` can change the number of runs, but must be at
least two.

## Rootfs ext4 and dm-verity reproducibility test

The ext4 and dm-verity stage can be tested repeatedly without rebuilding or
reinstalling the logical rootfs. Point the test at any retained logical rootfs
export containing `rootfs.tar`:

```bash
ROOTFS_ARTIFACT_DIR=/path/to/rootfs-export \
  src/image/tests/check_rootfs_verity_reproducibility.sh
```

The test performs three independent no-cache image builds from the same tar and
compares `rootfs.ext4`, `rootfs.verity`, the root hash, and the verity metadata.
Use `ROOTFS_VERITY_REPRO_RUNS` to change the run count (minimum two), and
`KEEP_ROOTFS_VERITY_REPRO_OUTPUT=1` to retain the generated blobs.
The test requires a Buildx builder with the `security.insecure` entitlement,
because a complete rootfs tar can contain device nodes.

The main image build uses the same implementation. It creates the complete
ext4 and dm-verity partition blobs before allocating the GPT image, then writes
the blobs byte-for-byte into the `rootfs` and `rootfs_hash` partitions.

## Complete disk image reproducibility test

The final raw image is deterministic as well. The build pins the disk and
partition GUIDs, ext4 UUIDs and directory hash seeds, FAT volume ID, GRUB input,
dm-verity UUID and salt, and timestamps. Boot ext4 and ESP are created as
canonical blobs; GPT partitions are written at fixed offsets. BIOS GRUB is
embedded into the dedicated partition and the canonical boot blob is restored
afterwards, so mounting during BIOS setup cannot change the output.

Use an existing logical rootfs export to test the whole disk without rebuilding
or reinstalling the rootfs:

```bash
ROOTFS_ARTIFACT_DIR=/path/to/rootfs-export \
  src/image/tests/check_disk_image_reproducibility.sh
```

The test performs three independent no-cache builds and compares SHA-256 of the
entire `sp-vm-repro-test.img`, including the protective MBR, BIOS GRUB, primary
and backup GPT, boot ext4, ESP FAT32, rootfs ext4, and dm-verity tree. Set
`DISK_IMAGE_REPRO_RUNS` to change the run count and
`KEEP_DISK_IMAGE_REPRO_OUTPUT=1` to retain the images. Reproducibility assumes
identical build arguments, including `SP_VM_IMAGE_VERSION`.

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

## Cloud Scripts
Cloud-specific helpers live in `scripts/<cloud>/`:

- `scripts/gcp/upload_custom_conf_image.sh`, `scripts/gcp/run_custom_conf_vm.sh`:
  upload an image to GCE and run a VM. `run_custom_conf_vm.sh` looks for
  `provider_config/` and `.s3_credentials` next to itself, so keep them in
  `scripts/gcp/` (both are git-ignored).
- `scripts/azure/ensure_gallery_image.sh`: make a build available as an Azure
  Compute Gallery image version.
- `scripts/azure/run_custom_conf_vm.sh`: launch a TDX Confidential VM from such
  an image and hand it a `provider_config`. Looks for `provider_config/` next to
  itself by default, like the GCP script (git-ignored).

### Azure Compute Gallery
An Azure VM can only be created from an image version in a gallery, and a
Confidential VM image can only be imported from a VHD. The script does that in
your own subscription: it fetches the build from Storj, verifies it against
both hashes in `vm.json`, turns it into a fixed VHD, uploads it as a staging
page blob and creates image version `<N>.0.0` of image definition
`sp-vm-<debug|release>` in gallery `sp-vm-images/sp_vm_images` (`westus3`).
Missing resources are created; the staging blob is deleted afterwards. The
image definition is Specialized, Gen2, and supports both Confidential
(TDX / SEV-SNP) and regular VMs.

Nothing is transferred when the image is already there:

- the version is found by build tag and its contents confirmed by the
  `image_sha256` tag (the hash of the raw image), so a repeat run costs one API
  call;
- a missing region is replicated from the existing version inside Azure;
- the same image in another gallery of the subscription is used as the source;
- a version left in `Failed` state is recreated, and a version with other
  contents is never overwritten without `--force-overwrite-image`.

The first run takes around 15 minutes, most of it spent waiting for Azure to
create the version.

Requirements: Contributor on the target resource group, plus Azure CLI,
`uplink`, `zstd` and (optionally, for faster uploads) `azcopy`. Alternatively
`scripts/azure/ensure_gallery_image_docker.sh` runs the same script in a
container built from `scripts/azure/Dockerfile` that has all of them, so the
host needs only Docker. It logs in with the `AZURE_CREDENTIALS` service
principal JSON (`clientId`, `clientSecret`, `tenantId`, `subscriptionId`) when
set, otherwise it reuses the host `az login` session from `~/.azure`.

```bash
# From a published build, only Docker required
scripts/azure/ensure_gallery_image_docker.sh --release build-441-release

# From a local build, host Azure CLI
scripts/azure/ensure_gallery_image.sh --raw out/sp-vm-build-441-debug.img

# See --help for gallery, region, verification and overwrite options
scripts/azure/ensure_gallery_image.sh --help
```

### Running a VM

`run_custom_conf_vm.sh` does the whole launch: it makes sure the image version
exists (calling `ensure_gallery_image.sh`), ships the `provider_config` and
creates the VM.

Put the operator's files in `scripts/azure/provider_config/`, in the same
layout the guest expects under `/sp`:

```
scripts/azure/provider_config/
├── swarm/
│   ├── config.yaml
│   └── openresty.yaml
└── authorized_keys        # debug images only
```

```bash
# Everything: image into the gallery, config to the VM, VM up
scripts/azure/run_custom_conf_vm.sh --release build-441-debug --vm my-vm

# Delete the VM, its disks, NIC, public IP and the config storage
scripts/azure/run_custom_conf_vm.sh --vm my-vm --delete

# See --help for size, zone, state disk and TTL options
scripts/azure/run_custom_conf_vm.sh --help
```

`scripts/azure/run_custom_conf_vm_docker.sh` runs the same thing in the
container, so the host needs only Docker.

**How the config gets in.** The directory is packed into a `tar.gz` and uploaded
to a storage account created in the VM's own resource group. The VM's userData
carries a read-only SAS URL and the archive's SHA-256. On boot the guest reads
userData from Azure IMDS, downloads the archive, verifies the hash and unpacks
it into `/sp`, which lives on the encrypted state disk. A lifecycle rule on that
storage account deletes the archive a day later.

Everything belonging to one launch lives in one resource group
(`sp-vm-<vm name>` by default) — VM, OS disk, state disk, NIC, public IP and the
config storage account — so `--delete` removes all of it at once.

**Using the VM's built-in disk as the state disk.** Some sizes ship with a large
local disk of their own — `Standard_NCC40ads_H100_v5`, for instance, comes with
about 800 GB. Paying for a managed data disk next to it makes no sense, so pass
`--state-disk-size 0`: the script then omits `--data-disk-sizes-gb` entirely and
the guest picks the built-in disk on its own, because the initramfs takes the
largest block device that is neither the root disk nor the provider_config disk.

```bash
scripts/azure/run_custom_conf_vm.sh --release build-444-debug --vm gpu-vm \
    --size Standard_NCC40ads_H100_v5 --location centralus --zone 3 \
    --state-disk-size 0 --provider-config ./provider_config
```

The built-in disk is wiped on deallocation, but that costs nothing here: the
state disk is wiped and re-encrypted on every boot anyway. Check that the size
actually has such a disk before relying on this — `MaxResourceVolumeMB` in
`az vm list-skus --size <size> --location <region>` is 0 when it does not, and
the VM then fails to boot with `no eligible extra block devices found`.

**Network.** Azure's network security group blocks everything by default, so
the script opens the ports the guest firewall (`hardening-vm.sh`) accepts:
TCP 80, 443, 7946, 9180, 9443 and UDP 53, 7946, 51820; `az vm create` adds SSH.
For a VM created before this, or after changing the list, apply the rules
without restarting it:

```bash
scripts/azure/run_custom_conf_vm.sh --vm my-vm --update-network
```

**The VM does not survive a reboot.** The state disk is wiped and re-encrypted
with a fresh key on every boot, so `/sp` comes up empty, and by then the archive
may already be gone. Launch a new VM instead, or use
`--refresh-provider-config` to re-upload and restart.

Under the hood the VM is created like this. The GRUB image is not signed, so
Secure Boot must be disabled; the largest extra disk becomes the encrypted state
disk.

```bash
az vm create -g <rg> -n <vm> -l westus3 --zone 3 --size Standard_DC2es_v6 \
    --image /subscriptions/<sub>/resourceGroups/sp-vm-images/providers/Microsoft.Compute/galleries/sp_vm_images/images/sp-vm-debug/versions/441.0.0 \
    --specialized \
    --security-type ConfidentialVM --os-disk-security-encryption-type VMGuestStateOnly \
    --enable-vtpm true --enable-secure-boot false \
    --data-disk-sizes-gb 100 \
    --user-data userdata.json
```

## References
Some parts of the code, including [kernel configs](src/kernel/files/configs/fragments), were taken from or inspired by [Kata Containers](https://github.com/kata-containers/kata-containers), which is distributed under the [Apache-2.0 license](https://github.com/kata-containers/kata-containers/blob/main/LICENSE).
