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
- `scripts/azure/cluster.sh`: start a whole Swarm cluster — bootstrap and join
  nodes, TDX and SEV-SNP mixed — add nodes to it and delete it.

Every Azure script has a `*_docker.sh` twin that runs it in a container with
all the tools, so the host needs only Docker and an `az login` session.

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

### Running a cluster

`cluster.sh` starts a Swarm cluster from a specification and a
`provider_config` template. It creates every VM with `run_custom_conf_vm.sh`,
starts the nodes one at a time and waits for the cluster to accept each one
before the next.

```bash
cp scripts/azure/cluster.example.yaml cluster.yaml     # edit it

scripts/azure/cluster_docker.sh up --spec cluster.yaml --wait-ui
scripts/azure/cluster_docker.sh status --cluster azure-test
scripts/azure/cluster_docker.sh add --cluster azure-test \
    --node 'size=Standard_DC8as_v5,location=eastus,zone=1'
scripts/azure/cluster_docker.sh delete --cluster azure-test
```

**Specification.** See `scripts/azure/cluster.example.yaml`:

| Key | Meaning |
|---|---|
| `name` | cluster name, `^[a-z][a-z0-9-]{1,30}$` |
| `release` | sp-vm release tag; `--release` overrides it |
| `provider_config` | template directory, relative to the specification; `--provider-config` overrides it |
| `swarm_domain`, `pki_domain` | optional, override the template's domains |
| `defaults` | `size`, `location`, `zone`, `state_disk_size` for nodes that do not set them |
| `nodes` | at least 3; the first one is the bootstrap |

A node sets any of `size`, `location`, `zone`, `state_disk_size`. The size picks
the TEE: `Standard_DC*es_v6` is Intel TDX, `Standard_DC*as_v5` is AMD SEV-SNP,
and one cluster can mix them. `state_disk_size: 0` uses the VM's built-in disk
(see [Using the VM's built-in disk](#running-a-vm)).

The template is a normal `provider_config`: `swarm/config.yaml` with
`pki_authority.networkID`, the domains and the service tags, plus
`swarm/openresty.yaml`. The script fills in the node-specific fields for each
node: `swarm_db.node_name`, and on join nodes `join_addresses`,
`pki_authority.servers` and `pki_authority.caBundle`. `advertise_addr` is
removed; every VM detects its own public address.

**Node names** are generated, never set by hand:
`<cluster>-node-<N>-<4 random characters>`, e.g. `azure-test-node-2-k7q2`. `N`
is the largest index among the cluster's current nodes plus one; the random
part keeps names unique even when an index is reused after a node was deleted.
The same name is the Azure VM name and the node's name inside the Swarm; the VM
lives in resource group `sp-vm-<name>`.

**How `up` proceeds.**

1. The bootstrap is created. The script waits for the Measurement API
   (`:9180/api/v1/getMeasure`) and reads the node's TEE type and `mrEnclave`.
2. On a release build, the `mrEnclave` must be in the trusted registry (below)
   before anything else happens.
3. The script waits until the bootstrap serves its CA on `:9443` and gossip is
   open on `:7946`, then saves the CA.
4. Each join node is created with the CA and the addresses of the nodes already
   in the cluster, goes through the same Measurement API and registry steps,
   and counts as joined once its own `:9443` serves the same CA — the cluster
   accepted its attestation. Only then the next node starts.
5. With `--wait-ui`, the script waits until `https://<swarm_domain>/` and its
   `/graphql` API both answer 200 (`--ui-timeout`, default 30 minutes). The
   page alone answers 200 before the API routes exist. If the UI does not come
   up in time, the script still prints the status table and exits with an
   error; the nodes stay as they are.

Each node may take `--node-timeout` seconds (default 1800) to boot and join. On
failure the script stops, prints what the node answered and keeps everything
for inspection. Running the same `up` again continues where it stopped: nodes
that already serve the cluster CA are skipped.

**Trusted registry.** On a `build-<N>-release` build, the PKI accepts a node
only if its `mrEnclave` is in
[`signatures/`](https://github.com/Super-Protocol/sp-vm/tree/main/signatures)
of this repository. For every node the script looks for the file where the PKI
looks: `signatures/<type>/{latest,pre-release}/mrenclave-<hex>.json`, then the
base folder of the platform (`tdx` for `tdx-azure`, `sev-snp` for
`sev-snp-azure`), then `mrenclave-<hex>.sign`. If it is missing, the script
prints the type, the value and the expected path, and waits without a timeout
until it appears; raw.githubusercontent.com caches for a few minutes. Nodes of
the same platform and release share one `mrEnclave`, so usually only the
bootstrap and the first node of another platform stop here. Debug builds skip
the registry; `--skip-registry` skips it explicitly.

**Domains.** Two running clusters with the same `swarm_domain` overwrite each
other's DNS records. Before creating the bootstrap, `up` requests
`https://<swarm_domain>/`; if something answers, it says so and asks whether to
continue. A record left over from a deleted cluster answers nothing and does
not stop the start. To run a second cluster from the same template, set
`swarm_domain` and `pki_domain` in its specification.

**Adding nodes.** `add` needs the cluster name and, optionally, one `--node`
per new node (fields not given come from `defaults`; no `--node` adds one node
of defaults). It finds the cluster by the `sp-cluster` tag, checks that every
node which answers serves the cluster CA, renders the new node's config with
the addresses of all live nodes — the bootstrap does not have to be alive — and
then follows step 4 above. `--release` adds a node of another release, for
example to replace nodes one by one. If `add` is interrupted, the next `add`
for that cluster continues it — the node that was being added and the ones
not started yet — and ignores its own `--node` arguments, so running the same
command again adds nothing twice. To remove a single node, delete its
resource group: `run_custom_conf_vm.sh --vm <node name> --delete`.

**Status and deletion.** `status` lists every node with its size, location,
IP, TEE type, `mrEnclave`, registry presence and whether it serves the cluster
CA, and checks the UI. `delete` removes all resource groups of the cluster in
parallel after a confirmation (`--yes` skips it) and then the local state.

**Where things are kept.** Azure is the source of truth for which nodes exist:
every resource group carries the tags `sp-cluster`, `sp-node`, `sp-index`,
`sp-role` and `sp-release`, and `status`, `add` and `delete` work from them.
The local state in `$SP_VM_CLUSTER_STATE/<cluster>` (default
`~/.sp-vm/azure-clusters/<cluster>`, mode 0700) holds the normalized
specification, the cluster CA, the rendered configs — they contain the
template's secrets — and a log of every `mrEnclave` seen. Without it, `add`
takes the defaults and template from `--spec`, or `--provider-config` and
`--release`.

## References
Some parts of the code, including [kernel configs](src/kernel/files/configs/fragments), were taken from or inspired by [Kata Containers](https://github.com/kata-containers/kata-containers), which is distributed under the [Apache-2.0 license](https://github.com/kata-containers/kata-containers/blob/main/LICENSE).
