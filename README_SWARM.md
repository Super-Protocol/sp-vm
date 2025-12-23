## Swarm deployment overview

This document describes how application deployment via Swarm is wired in `sp-vm` and which repository parts are involved.

### High-level architecture

- **swarm-db** (`src/repos/swarm-db`): replicated state database (similar to `etcd` in Kubernetes). It stores cluster policies (`ClusterPolicies`), service descriptions (`ClusterServices`), secrets, and other control-plane entities.
- **swarm-cloud / swarm-node** (`src/repos/swarm-cloud/apps/swarm-node`): the component that reads state from `swarm-db` and reconciles the real cluster to the desired state (creates/deletes clusters and nodes, deploys services, runs provisioning scripts, etc.).
- **VM image / configuration** (`sp-vm`): contains scripts and manifests of concrete applications that must be deployed via Swarm, plus utilities for writing the desired state into `swarm-db`.

The main idea: you **declare the desired state** (ClusterPolicy/ClusterService and service manifests), and `swarm-node` asynchronously drives the infrastructure towards that state.

---

## swarm-cli.py — single entrypoint for Swarm deployment

File: `src/swarm-scripts/swarm-cli.py`

- **Purpose**: the primary CLI for working with `swarm-db` entities related to application deployment via Swarm.
- Supported entities:
  - `ClusterPolicies`
  - `ClusterServices`
  - `SwarmSecrets`
- The CLI reads DB connection parameters from environment variables (`DB_HOST`, `DB_PORT` / `SWARM_DB_PORT` / `MYSQL_PORT`, `DB_USER`, `DB_NAME`, `DB_PASSWORD`), patches PyMySQL for dev/test environments, and executes parameterized SQL statements.

**Important:**

- For deploying new applications and services via Swarm you **must use `swarm-cli.py`**.
- If some functionality is missing, **extend `swarm-cli.py`** instead of adding ad‑hoc SQL scripts or custom logic in other places.
- This keeps a single contract for working with `swarm-db` and prevents drift in record formats.

Typical commands (illustrative, may differ from your exact wrappers):

- Create/update a cluster policy:

```bash
./swarm-cli.py create ClusterPolicies my-policy \
  --minSize 3 \
  --maxSize 5 \
  --maxClusters 1
```

- Create/update a service:

```bash
./swarm-cli.py create ClusterServices \
  --cluster_policy my-policy \
  --name my-service \
  --version 1 \
  --location /etc/swarm-cloud/services/my-service
```

---

## Where Swarm deployment scripts must live

Directory: `src/swarm-scripts`

- This directory must contain **top‑level scripts** that:
  - are invoked from systemd, cloud-init, CI/CD, etc.;
  - prepare basic environment and call `swarm-cli.py` to write the required entities into `swarm-db`.
- **Content requirements**:
  - these scripts **must not contain application business logic** or complex orchestration;
  - their main responsibility is to **prepare parameters and trigger Swarm deployment** via `swarm-cli.py` (create/update `ClusterPolicy`, `ClusterService`, `SwarmSecrets`, etc.).

Recommended pattern:

- every service that should be deployed via Swarm has a **small shell script** in `src/swarm-scripts` which:
  - gathers required parameters (policy ID, service name, version, path to manifest);
  - invokes `swarm-cli.py` with the right arguments;
  - optionally logs minimal steps.

---

## Where manifests and deployment stages live

Directory: `src/services/apps/*`

- For each application/service that is deployed via Swarm there must be:
  - a **manifest** `manifest.yaml` (or similar) describing deployment stages;
  - **deployment stage script(s)** that are executed by `swarm-node` during provisioning.
- Your VM image/config build process must copy these files into the final filesystem (typically under `/etc/swarm-cloud/services/<service-name>` inside the guest OS).

The usual flow:

- in `src/services/apps/<service-name>/` you keep `manifest.yaml` and helper scripts;
- when building `sp-vm`, these files are copied into `/etc/swarm-cloud/services/<service-name>` inside the image;
- when creating `ClusterServices`, `swarm-cli.py` reads `manifest.yaml` and **stores its contents into the `manifest` column of the `ClusterServices` table** (see `create_cluster_services` in `swarm-cli.py`);
- `swarm-node` then reads the service description from `swarm-db` and executes the corresponding deployment steps.

---

## swarm-db and deployment entities: ClusterPolicy and ClusterService

Sources: `src/repos/swarm-db` and `src/repos/swarm-cloud/libs/swarm-db`

### swarm-db

- `swarm-db` is a replicated database that stores the state of the entire Swarm cluster:
  - cluster formation and placement policies (`ClusterPolicies`, `ClusterPolicyMeasurementRules`, `ClusterPolicyAffinityRules`);
  - clusters and their nodes (`Clusters`, `ClusterNodes`, `ClusterProperties`, etc.);
  - service descriptions (`ClusterServices`);
  - auxiliary entities (secrets, measurements, quorum policies, etc.).
- In the TypeScript layer (library `@swarm-cloud/swarm-db`) this is modeled as a set of `typeorm` entities, e.g.:
  - `ClusterPolicy` (backed by `ClusterPolicies` table);
  - `ClusterService` (backed by `ClusterServices` table);
  - `Cluster`, `ClusterNode`, `Measurement`, `QuorumPolicy`, and others.

### ClusterPolicy: what it describes

Entity: `ClusterPolicy` (`ClusterPolicies` table, see `libs/swarm-db/src/entities/cluster-policy.entity.ts` in `swarm-cloud`).

- Fields:
  - `id`: string policy identifier (e.g. `redis`, `cockroachdb`, `swarm-cloud-api`);
  - `minSize`: minimum number of nodes in a cluster;
  - `maxSize`: maximum number of nodes in a cluster;
  - `maxClusters`: how many clusters with this policy may exist at all;
  - relations to:
    - `ClusterPolicyMeasurementRule` — rules based on measurements (latency, etc.);
    - `ClusterPolicyAffinityRule` — affinity / anti-affinity rules towards other policies;
    - `Cluster` — clusters created under this policy;
    - `ClusterService` — services that must be deployed in clusters of this policy.

Intuitively:

- `ClusterPolicy` is a **declarative description of what clusters you need and what services should run on them**.
- Examples:
  - policy `redis` may require at least 3 nodes and exactly one cluster;
  - policy `swarm-cloud-api` may be affine to policy `cockroachdb` so that API nodes are close to the DB.

### ClusterService: what it describes

Entity: `ClusterService` (`ClusterServices` table, see `libs/swarm-db/src/entities/cluster-service.entity.ts` in `swarm-cloud`).

- Fields:
  - `id`: string service identifier (`<cluster_policy>:<service-name>`, e.g. `redis:redis`);
  - `cluster_policy`: reference to `ClusterPolicy.id` this service belongs to;
  - `name`: service name (usually aligned with directories/names used in manifests);
  - `version`: version (used for rolling upgrades/migrations);
  - `location`: logical location of service artifacts (written as `dir://...` in `swarm-cli.py`);
  - `hash`: optional content hash (can be used for change detection);
  - `manifest`: YAML manifest of the service (a copy of your `manifest.yaml`);
  - `updated_ts`: last update timestamp.

Intuitively:

- `ClusterService` is a **description of which service must be deployed under which policy**, with links to version and actual files (manifest).
- The `ClusterPolicy` → `ClusterService` link allows `swarm-node` to:
  - understand which services must be deployed in clusters with a given policy;
  - trigger update/re-provisioning when version or manifest changes.

---

## swarm-node: how it uses swarm-db for deployment

Sources: `src/repos/swarm-cloud/apps/swarm-node`

- `swarm-node` is a worker/daemon that:
  - tracks its own status in the cluster (via `LocalNodePointer` and other entities from `@swarm-cloud/swarm-db`);
  - periodically performs “tick” logic (see `ProvisionWorkerService` and related services);
  - reads from `swarm-db`:
    - current `ClusterPolicies`, `Clusters`, `ClusterNodes`;
    - the list of `ClusterServices` and their manifests;
  - based on that, **reconciles the local machine and environment to the desired state**:
    - creates/deletes/updates local resources;
    - executes steps from `manifest.yaml` for services of its policy;
    - manages local cache, locks, retries, etc.

The key idea:

- from `sp-vm` you **prepare the necessary records in `swarm-db`** (via `swarm-cli.py`) and the corresponding manifests;
- `swarm-node`, running inside the cluster, picks up this state and **performs deployment on its own**, without additional logic baked into the VM image.

---

## Recommendations for extension and evolution

- **If you need to add a new type of deployment entity**:
  - first add/extend the entity in `swarm-db` (Go/TS layer);
  - then add support for it in `swarm-cli.py` (new command/option);
  - only after that add thin wrapper scripts in `src/swarm-scripts`.
- **Do not put heavy business logic into `src/swarm-scripts`**:
  - everything related to planning, placement and lifecycle of services should live in `swarm-node` and related libraries;
  - `sp-vm` should remain a mostly declarative description of what needs to be deployed.


