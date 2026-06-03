# Kubernetes CNI (RKE2 / Canal)

`/etc/cni/net.d/` on the node is used by kubelet when RKE2 is deployed.
Canal installs `10-canal.conflist` and related files there at runtime.

Podman CNI configs must not live in that directory — they belong under
`/etc/cni/podman/net.d/` (see `/etc/containers/containers.conf.d/99-podman-cni-dir.conf`).
`configure-podman-cni.sh` runs at boot and after each apt transaction
(`/etc/apt/apt.conf.d/99-sp-configure-podman-cni`).

Nodes without RKE2 keep `/etc/cni/net.d/` empty.
