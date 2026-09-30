# Swarm cluster on Azure: operator guide

How to start, grow and delete a Super Protocol Swarm cluster of Azure
confidential VMs (Intel TDX and AMD SEV-SNP) with `scripts/azure/cluster.sh`.

Russian version: [CLUSTER_RU.md](CLUSTER_RU.md).

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [provider_config template](#provider_config-template)
- [Cluster specification](#cluster-specification)
- [Starting a cluster](#starting-a-cluster)
- [Adding nodes](#adding-nodes)
- [Cluster status](#cluster-status)
- [Deleting](#deleting)
- [Where cluster information is kept](#where-cluster-information-is-kept)
- [Trusted mrEnclave registry](#trusted-mrenclave-registry)
- [VM sizes, regions, quotas, cost](#vm-sizes-regions-quotas-cost)
- [Pitfalls](#pitfalls)
- [When something goes wrong](#when-something-goes-wrong)

## How it works

A cluster is one bootstrap VM and at least two join VMs. Each VM is a separate
Azure confidential VM with its own state disk and its own resource group.
Nodes talk to each other over public addresses.

```
cluster.sh ──► run_custom_conf_vm.sh ──► ensure_gallery_image.sh
 (order,          (one VM: provider_config          (the build image
  waits,           in a blob + SAS, NSG, disk)        in Azure Compute Gallery)
  registry)
```

`cluster.sh` does not create VMs itself: the existing scripts do all of that,
and it decides what to start and when. What `up` does:

1. Creates the bootstrap.
2. Waits for the node's Measurement API (`:9180/api/v1/getMeasure`) and reads
   the TEE type and `mrEnclave`.
3. **Release builds only:** the `mrEnclave` must be in the trusted registry. If
   it is not, the script prints the value and waits, without a timeout.
4. Waits until the bootstrap serves the root CA (`:9443`) and gossip is open
   (`:7946`), and saves the CA.
5. Creates the join nodes **one at a time**. Each gets the CA and the addresses
   of the nodes already in the cluster, and goes through steps 2–3. A node
   counts as joined when its own `:9443` serves the same CA: the cluster has
   verified its attestation and issued its certificate. Only then is the next
   node created.
6. With `--wait-ui`, waits for the cluster web UI.

## Prerequisites

**On the machine you run it from:**

| What | Why |
|---|---|
| Linux, bash | the scripts |
| Docker with `buildx` | everything runs in the `sp-vm-azure-tools` container (Azure CLI, azcopy, uplink, jq, python3-yaml). The image builds itself on first use |
| `az login` or a service principal | the container reuses the session in `~/.azure` (or `$AZURE_CONFIG_DIR`); or pass a service principal JSON in `AZURE_CREDENTIALS` (`clientId`, `clientSecret`, `tenantId`, `subscriptionId`) |
| ~10 GB free in the current directory | only the first time a build is used: the image is downloaded from Storj and turned into a VHD (~4.5 GB) in the current directory |
| a clone of `sp-vm` | the scripts are in `scripts/azure/` |

**Without Docker.** Nothing is detected automatically: you choose by which
script you call. `cluster_docker.sh` runs `cluster.sh` in the container;
calling `cluster.sh` directly runs it on the host, with the same arguments.
The host then needs:

| Tool | Needed |
|---|---|
| `az`, `jq`, `curl`, `python3` with `PyYAML`, `openssl`, `sha256sum`, `tar`, `ssh-keygen`, `timeout` | always |
| `uplink`, `zstd` | only when the build is not in the gallery yet and has to be imported from Storj |
| `azcopy` | optional: speeds up the VHD upload of a new build; without it `az storage blob upload` is used |

`up` and `add` check all of this before creating the first VM and list what is
missing, so a native run fails at once rather than halfway through a cluster.

**In Azure:**

- a subscription with rights to create resource groups, VMs, disks, public IPs,
  storage accounts and gallery image versions;
- vCPU quota for the VM families in the regions you use (see
  [below](#vm-sizes-regions-quotas-cost));
- the gallery `sp_vm_images` in resource group `sp-vm-images` is created on
  first use.

**Other:**

- a `provider_config` template with working secrets (next section);
- for a release build, a way to get the `mrEnclave` into the registry (it is
  signed by Super Protocol).

## provider_config template

A directory that becomes `/sp` on every VM. One template serves all nodes: the
script fills in whatever differs between them.

```
provider-config/
├── swarm/
│   ├── config.yaml       # required
│   └── openresty.yaml    # ACME for the TLS certificates
└── authorized_keys       # optional, works only on debug builds
```

### `swarm/config.yaml`

```yaml
github:
  token: "<GITHUB_TOKEN>"          # PAT with access to ghcr.io and the private repositories

tags:                              # component versions the node downloads at start
  swarm_db: "v1.1.4"
  host_agent: "develop"
  swarm_node: "develop"
  sdk: "develop"
  services: "develop"
  pki_authority: "v5.1.0"
  swarm_cloud_api: "develop"
  swarm_cloud_ui: "develop"
  auth_service: "develop"
  gatekeeper_s3_image: "ghcr.io/super-protocol/swarm-cloud/swarm-gatekeeper:develop"
  gatekeeper_harbor_image: "ghcr.io/super-protocol/swarm-cloud/swarm-gatekeeper:develop"

swarm_db:
  node_name: "anything"            # overwritten for each node
  join_addresses: []               # overwritten
  # advertise_addr — leave it out: the script removes it, each VM detects its own address

pki_authority:
  networkID: "<NETWORK_ID>"        # the same on every node of a cluster; required

powerdns_api_url: "https://pdns.example.com"
powerdns_api_key: "<POWERDNS_API_KEY>"
base_domain: "example.com"
swarm_domain: "swarm.example.com"     # web UI address; a subdomain of base_domain
pki_domain: "ca.swarm.example.com"    # PKI Authority address
# global_id: ""                    # leave it out, see Pitfalls
```

What the script changes in each node's copy of the template:

| Field | bootstrap | join |
|---|---|---|
| `swarm_db.node_name` | node name | node name |
| `swarm_db.advertise_addr` | removed | removed |
| `swarm_db.join_addresses` | `[]` | `<ip>:7946` of every node already in the cluster |
| `pki_authority.caBundle` | removed | the cluster CA |
| `pki_authority.servers` | removed | `<ip>:9443` of every node already in the cluster |
| `swarm_domain`, `pki_domain` | from the specification, if set there | same |

The script does not touch `networkID`; it only checks that it is set.

### `swarm/openresty.yaml`

```yaml
EAB_KID: <EAB_KID>
EAB_HMAC_KEY: <EAB_HMAC_KEY>
ACME_PROVIDER: zerossl
ACME_URL: https://acme.zerossl.com/v2/DV90
```

### `authorized_keys`

Public ssh keys in the usual format. Useful only on `*-debug` builds: release
builds have ssh closed.

### Where to keep the template

Outside the repository: it holds tokens. `.gitignore` already covers
`scripts/**/provider_config/`, but a separate directory such as
`~/projects/cluster-config/provider-config/` is safer.

## Cluster specification

A YAML file; see `scripts/azure/cluster.example.yaml`.

```yaml
name: azure-test                    # cluster name: ^[a-z][a-z0-9-]{1,30}$
release: build-445-release          # sp-vm release tag; --release overrides it
provider_config: /home/me/projects/cluster-config/provider-config
                                    # a relative path is resolved against this file's directory
# swarm_domain: swarm2.example.com     # optional: override the template's domains
# pki_domain: ca.swarm2.example.com

defaults:                           # for nodes that do not set a field
  size: Standard_DC8es_v6           # TDX, 8 vCPU / 32 GB
  location: westus3
  zone: "3"
  state_disk_size: 300              # GB; 0 = the VM's built-in disk (NCC H100)

nodes:                              # at least 3; the first one is the bootstrap
  - {}
  - {}
  - { size: Standard_DC8as_v5, location: eastus, zone: "1" }   # SEV-SNP
```

- A node can set only `size`, `location`, `zone`, `state_disk_size`. **Its name
  cannot be set** (see [node names](#node-names)).
- The size picks the platform: `Standard_DC*es_v6` is Intel TDX,
  `Standard_DC*as_v5` is AMD SEV-SNP. One cluster can mix them.
- Regions and zones can be mixed too: nodes talk over public IPs.

## Starting a cluster

```bash
cd ~/projects/sp-vm/scripts/azure
./cluster_docker.sh up --spec ~/projects/cluster-config/azure-test.yaml --wait-ui
```

| Option | Meaning |
|---|---|
| `--spec <file>` | the specification (required) |
| `--release <tag>` | override `release` of the specification |
| `--provider-config <dir>` | override `provider_config` of the specification |
| `--wait-ui` | after the last node, wait for the web UI |
| `--ui-timeout <sec>` | default 1800 |
| `--node-timeout <sec>` | how long each node may take to boot and join; default 1800 |
| `--skip-registry` | do not wait for the `mrEnclave` in the registry |

What you will see:

```
[20:34:15] Cluster rtest: 3 nodes, build-445-release (release, trusted registry enforced)
[20:34:23] rtest-node-1-mct4: creating (Standard_DC8es_v6, westus3 zone 3, state disk 300 GB)
    ...run_custom_conf_vm.sh output, indented...
[20:35:51] rtest-node-1-mct4: VM up, public IP 203.0.113.10
[20:36:41] rtest-node-1-mct4: tdx-azure mrEnclave 3b87e54d…
[20:36:42] rtest-node-1-mct4: mrEnclave is in the trusted registry
[20:40:06] rtest-node-1-mct4: PKI serves the CA, gossip is open
[20:40:15] rtest-node-2-hiej: joins through 203.0.113.10
...
[20:48:41] rtest-node-3-pqtc: joined
[20:59:34] UI is up: https://swarm.example.com/
```

The `status` table is printed at the end.

**Timing.** The bootstrap takes about 6 minutes, each join node another 4–5,
and the UI 10–15 minutes after the last node. Three nodes on 8-core VMs take
25–35 minutes in total. Add ~13 minutes when the build is not in the gallery
yet, and a few minutes of replication for the first node in a new region.

**Continuing after an interruption.** Ctrl-C or a failed node stops the
script; nothing created is deleted. Running **the same command** again
continues where it stopped: nodes that already serve the cluster CA are
skipped.

**DNS check.** Before creating the bootstrap, the script requests
`https://<swarm_domain>/`. If the address answers, another cluster is running
on that domain; the script asks whether to continue, and without a terminal it
stops.

## Adding nodes

```bash
# one node, all from defaults
./cluster_docker.sh add --cluster azure-test

# a node with its own parameters
./cluster_docker.sh add --cluster azure-test --node 'size=Standard_DC8as_v5,location=eastus,zone=1'

# several nodes: added strictly one at a time
./cluster_docker.sh add --cluster azure-test --node '' --node 'size=Standard_DC8as_v5,location=eastus,zone=1'
```

| Option | Meaning |
|---|---|
| `--cluster <name>` | required |
| `--node 'k=v,...'` | node fields: `size`, `location`, `zone`, `state_disk_size`; missing ones come from `defaults`. `''` is a node made entirely of `defaults`. Repeatable; without `--node` one node of `defaults` is added |
| `--release <tag>` | another build for the new nodes, for example to replace nodes one by one; the script warns about mixed versions |
| `--provider-config <dir>` | another template |
| `--spec <file>` | where to take `defaults`, the template and the release from when there is no local state (another machine) |
| `--node-timeout`, `--skip-registry` | as for `up` |

What happens:

1. The script finds the cluster's nodes by the `sp-cluster` tag in Azure.
2. It checks that every node that answers serves the cluster CA. If one serves
   a different CA, it stops: the resource groups mix in another cluster.
3. It creates the node with the addresses of **all live** nodes. The bootstrap
   does not have to be alive.
4. It waits for the Measurement API and the registry (release builds), then
   for the node to join.

**An interrupted `add`** is continued by the next `add` for the same cluster:
it finishes the node that was being added and the rest of that command, and
ignores its own `--node` arguments. Running the same command again adds
nothing twice.

**From another machine**, without local state:

```bash
./cluster_docker.sh add --cluster azure-test --spec ~/projects/cluster-config/azure-test.yaml
```

Without `--spec` you need `--provider-config` and `--release`, and every node
field must be given: there is nowhere to take `defaults` from. Domain overrides
from the specification are unknown then as well, so passing `--spec` is
better.

### Removing a single node

There is no separate command. Delete the node's resource group:

```bash
./run_custom_conf_vm_docker.sh --vm azure-test-node-4-k7q2 --delete
```

The node stays in swarm-db until it is considered dead by timeout; that is
swarm's behaviour, not the script's.

## Cluster status

```bash
./cluster_docker.sh status --cluster azure-test
```

```
NODE                  ROLE      SIZE               LOCATION   IP              TEE           MRENCLAVE         REGISTRY CA
rtest-node-1-mct4     bootstrap Standard_DC8es_v6  westus3/3  203.0.113.10    tdx-azure     3b87e54d9c175958  yes      ok
rtest-node-2-hiej     join      Standard_DC8es_v6  westus3/3  203.0.113.11    tdx-azure     3b87e54d9c175958  yes      ok
rtest-node-3-pqtc     join      Standard_DC8as_v5  eastus/1   203.0.113.12    sev-snp-azure 1cccb72fb97be3a0  yes      ok

UI: https://swarm.example.com/ is up
```

| Column | Meaning |
|---|---|
| `REGISTRY` | `yes` / `no` — whether the `mrEnclave` is in the registry; `debug` — not checked for debug builds |
| `CA` | `ok` — the node serves the cluster CA; `other` — a different CA; `down` — PKI does not answer |
| `UI` | whether `https://<swarm_domain>/` and `/graphql` answer |

`status` queries every node, so it takes from tens of seconds to a couple of
minutes.

## Deleting

```bash
./cluster_docker.sh delete --cluster azure-test          # asks for confirmation
./cluster_docker.sh delete --cluster azure-test --yes    # no question
```

All resource groups tagged `sp-cluster=azure-test` are deleted in parallel:
VMs, disks, network interfaces, IPs, provider_config storage. The script then
checks that nothing is left and removes the local state. It usually takes 5–8
minutes.

The image gallery `sp-vm-images` is not deleted: all clusters share it. The DNS
records in PowerDNS stay as well. They do not get in the way of a new cluster
on the same domain: the start checks whether the address answers, not whether
a record exists.

## Where cluster information is kept

**Azure is the source of truth.** Each node's resource group carries tags:

| Tag | Example |
|---|---|
| `sp-cluster` | `azure-test` |
| `sp-node` | `azure-test-node-2-k7q2` |
| `sp-index` | `2` |
| `sp-role` | `bootstrap` / `join` |
| `sp-release` | `build-445-release` |

`status`, `add` and `delete` find the nodes by these tags, so they work from
any machine. To look by hand:

```bash
az group list --tag sp-cluster=azure-test -o table
```

**Local state** is in `$SP_VM_CLUSTER_STATE/<cluster>`, by default
`~/.sp-vm/azure-clusters/<cluster>/`, mode 0700:

| File | Contents |
|---|---|
| `spec.json` | the normalized specification the cluster was started with, and the nodes added with `add` (`added`) |
| `ca.pem` | the cluster root CA |
| `nodes/<node>/` | each node's rendered provider_config. **Contains the template's secrets** |
| `swarm_domain` | the UI domain |
| `mrenclave.log` | every `mrEnclave` seen: time, node, type, value, build |
| `defaults.json` | `defaults` for `add` |
| `pending.json` | the queue of an interrupted `add`; present only until it finishes |

`add` needs the state (template, `defaults`, CA), and so does continuing `up`.
If it is lost the cluster keeps running: `status` and `delete` do not need it,
and `add` accepts `--spec`.

### Node names

Names are generated by the script: `<cluster>-node-<N>-<4 random characters>`,
for example `azure-test-node-2-k7q2`. `N` is the largest index among the
current nodes plus one. The random tail keeps a name unique even when the index
of a deleted node comes around again. The same name is the Azure VM name, the
`node_name` in swarm-db and part of the resource group name `sp-vm-<name>`.

## Trusted mrEnclave registry

On **release** builds (`build-<N>-release`) the PKI accepts a node only if its
`mrEnclave` is in `signatures/` of the `Super-Protocol/sp-vm` repository
(branch `main`). The script looks for the file the way the PKI does:

1. `signatures/<type>/latest/mrenclave-<hex>.json`, then `.../pre-release/...`;
2. the same in the platform's base folder: `tdx` for `tdx-azure`, `sev-snp` for
   `sev-snp-azure`;
3. `signatures/mrenclave-<hex>.sign`.

If the file is missing, the script prints:

```
================================================================================
 mrEnclave of azure-test-node-1-ab2c is not in the trusted registry yet.
 The cluster will not continue until it is added.

   node:       azure-test-node-1-ab2c (bootstrap, 203.0.113.20)
   type:       tdx-azure
   mrEnclave:  3b87e54d…
   expected:   signatures/tdx-azure/pre-release/mrenclave-3b87e54d….json
               in github.com/Super-Protocol/sp-vm (main)
================================================================================
```

and checks every 30 seconds **without a timeout**. After the file is added,
allow a few minutes: raw.githubusercontent.com caches responses for up to ~5
minutes.

Worth knowing:

- `mrEnclave` depends on the build and the platform, but **not on the VM
  size**. Nodes of one platform and one build share one value, so usually only
  the bootstrap and the first node of another platform stop here.
- TDX and SEV-SNP of the same build give **different** values: both have to be
  added.
- A debug and a release build of the same number differ too.
- Debug builds skip the registry.

Values for `build-445-release`: TDX `3b87e54d9c1759585e0bed03646374f52b39433e8389ff945cd6ed31071dfeb5`,
SEV-SNP `1cccb72fb97be3a057f65eccdc4f92e6d2c2b0b17caaa81ed95400927c678ea7`.

## VM sizes, regions, quotas, cost

| Size | TEE | vCPU / RAM | Available in | $/h (pay-as-you-go) |
|---|---|---|---|---|
| `Standard_DC2es_v6` | TDX | 2 / 8 GB | westus3 and others | 0.111 |
| `Standard_DC4es_v6` | TDX | 4 / 16 GB | westus3 and others | 0.222 |
| `Standard_DC8es_v6` | TDX | 8 / 32 GB | westus3 and others | 0.444 |
| `Standard_DC2as_v5` … `DC8as_v5` | SEV-SNP | 2–8 / 8–32 GB | eastus (v5 is not offered in westus3) | — |
| `Standard_NCC40ads_H100_v5` | SEV-SNP + H100 | 40 / 320 GB + 1×H100 | centralus, eastus2, westeurope | 7.89 |

The state disk is Premium SSD, billed by tier: 100 GB is P10 ($17.92/month),
256 GB is P15 ($34.56/month), and 300 GB is already P20 = 512 GB
($66.56/month). A cluster of three `DC8es_v6` with 300 GB disks costs about
$1.6 an hour, roughly $39 a day.

**Recommendation:** 8 vCPU / 32 GB. On 2-core nodes (tested with
`build-444-debug`) the nodes join, but the full service stack does not
converge: openresty and redis stay in `Applying` and the UI never comes up. On
4-core nodes `harbor-jobservice` did not start.

**Guest memory** is about 30 GB out of 32: ~1 GB goes to the SWIOTLB bounce
buffers of a confidential VM, the rest to the kernel's reserve.

**Check the quotas** before starting:

```bash
az vm list-usage -l westus3 -o table | grep -Ei 'DCEV6|DCASv5|Total Regional'
az vm list-usage -l eastus  -o table | grep -Ei 'DCASv5|Total Regional'
```

There are usually two limits: per family (`Standard DCEV6 Family vCPUs`) and
per region (`Total Regional vCPUs`). A cluster of three 8-core nodes needs 24
vCPUs.

**H100 and the built-in disk.** `NCC40ads_H100_v5` has a local disk of ~800 GB.
Set `state_disk_size: 0` and it becomes the state disk, with no separate paid
disk. Do not do this on sizes without a local disk (`MaxResourceVolumeMB` in
`az vm list-skus` is 0): the VM will not boot.

## Pitfalls

- **A VM does not survive a reboot.** The state disk is wiped and re-encrypted
  on every boot, and the provider_config archive lives in the blob for one day
  only. Do not stop or restart nodes. Replace a node that Azure rebooted:
  delete it and `add` a new one.
- **A stopped VM still costs money** for its disks. Only `delete` saves.
- **One domain, one cluster.** Two running clusters with the same
  `swarm_domain`/`pki_domain` overwrite each other's DNS records. For a second
  cluster from the same template, set its own `swarm_domain` and `pki_domain`
  in the specification.
- **Do not set `global_id` in the template.** Without it every cluster gets a
  random id, and the `gw.dyn.<global_id>…` records do not overlap. With a fixed
  `global_id`, two clusters conflict on all of them.
- **`networkID` is the same on every node of a cluster.** Change it in the
  template after `up`, and new nodes will not join.
- **Do not change the specification after `up`.** `up` with a different
  specification for a running cluster refuses. Grow the cluster with `add`;
  recreate it with `delete` and `up`.
- **A relative `provider_config`** is resolved against the specification's
  directory, not the current one. `home/me/...` without the leading `/` is a
  relative path.
- **"The UI answers 200" does not mean it works.** The page is served before
  the API routes exist, which is why `--wait-ui` checks `/graphql` as well.
- **`rke2` shown as `Degraded`** while Kubernetes is healthy is a known false
  alarm: the OPA health probe connects to `127.0.0.1`, while the certificate is
  issued for a DNS name.
- **`auth-service` / `route-manager` in `Removed` on one node** is normal: the
  scheduler moved them to another node.
- **Release builds are closed.** There is no ssh and no serial console on
  `*-release`. From outside you see only `:9180` (Measurement API), `:9443`
  (PKI) and, once the cluster has converged, `:80/443`.
- **Ports.** The NSG opens TCP 80, 443, 7946, 9180, 9443 and UDP 53, 7946,
  51820 — the same set the guest firewall accepts.
- **The first start of a new build** downloads and uploads the image (~13
  minutes, ~10 GB in the current directory). If it was interrupted, a
  `tmpdir.azure-image.*` directory may be left in the current directory; it can
  be deleted.
- **Without a terminal** (CI, `nohup`) the DNS check and the `delete`
  confirmation cannot ask: the DNS check stops the start, `delete` needs
  `--yes`.
- **The local state holds secrets** (the rendered configs). Do not share
  `~/.sp-vm/azure-clusters/`.

## When something goes wrong

If a node does not make it within `--node-timeout`, the script prints a summary
and stops:

```
Node azure-test-node-2-k7q2 failed: it did not join the cluster within --node-timeout (1800s).
  public IP:        203.0.113.20
  Measurement API:  tdx-azure 3b87e54d…
  PKI (9443):       no answer
  gossip (7946):    open
  resource group:   sp-vm-azure-test-node-2-k7q2 (kept for inspection)
  serial console:   az serial-console connect -g sp-vm-azure-test-node-2-k7q2 -n azure-test-node-2-k7q2
```

How to read it:

| Symptom | Likely cause |
|---|---|
| Measurement API does not answer | the VM did not boot, or the provider_config did not arrive (wrong template, expired blob) |
| Measurement API answers, PKI silent, release build | the `mrEnclave` was not accepted. Check the registry; with `--skip-registry` the script did not wait for it |
| PKI serves a different CA | the node came up as a bootstrap: its config has empty `join_addresses`, `caBundle` or `servers` |
| all nodes `ok`, the UI does not come up | the cluster is still converging, or the nodes are too small; see `status` and the sizes above |

Then fix the cause and run the same command again (`up` or `add`), or delete
the node and add it anew. On debug builds you can ssh in (with a key from the
template's `authorized_keys`) and look at swarm-db:

```bash
ssh root@<ip> 'mysql -h 127.0.0.1 -P 3306 -u root swarmdb -t -e "select node_name, addr, status from nodes"'
```
