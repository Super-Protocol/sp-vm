# Kubernetes CNI (RKE2 / Canal)

`/etc/cni/net.d/` on the node is used by kubelet when RKE2 is deployed.
Canal installs `10-canal.conflist` and related files there at runtime.

Podman CNI configs must not live in that directory — they belong under
`/etc/cni/podman/net.d/` (see `/etc/containers/containers.conf.d/99-podman-cni-dir.conf`).
`configure-podman-cni.sh` runs at boot and after each apt transaction
(`/etc/apt/apt.conf.d/99-sp-configure-podman-cni`).

Nodes without RKE2 keep `/etc/cni/net.d/` empty.

## The overlay rides on wg0 (SUP-350)

Canal is configured with `flannel.iface: wg0` and the `vxlan` backend, so
`flannel.1` — the device that carries all pod-to-pod traffic — is a VXLAN
interface whose lower device is `wg0`. Deleting `wg0`, which is exactly what
`wg-quick down` does (`ip link delete dev wg0`), makes the kernel
cascade-delete `flannel.1` and every `10.42.x.0/24` route with it.

flanneld builds `flannel.1` once at start-up and never notices. Without the
recovery below the node keeps running with no pod network at all while
`kubectl get nodes` reports `Ready`, the canal pod stays `2/2 Running` and
`wg show wg0` looks perfectly healthy.

`/usr/local/bin/sp-cni-after-wg0 wg0` restores it: if `wg0` exists and
`flannel.1` does not, it stops the `kube-flannel` container (`crictl`), which
rebuilds `flannel.1` against the current `wg0` and reinstalls the routes.
Running pods keep their IPs. Every "nothing to do" path exits 0, so it is a
no-op at boot and on nodes without RKE2. Two triggers:

- `wg-quick@wg0.service.d/10-cni-recovery.conf` — `ExecStartPost=-`, i.e. every
  interface (re-)creation that goes through the unit, including an operator's
  `systemctl restart wg-quick@wg0`. The drop-in also raises the unit's
  `TimeoutStartSec`, because a start timeout would make systemd stop the unit
  and delete `wg0` again.
- `sp-cni-after-wg0.timer` — every 60 s, for removals that bypass the unit
  (`ip link del wg0`). A failed rebuild backs off for 5 minutes instead of
  restarting flanneld on every tick.

Applying a peer change by hand is safe through `systemctl reload wg-quick@wg0`
(`wg syncconf`); it does not touch `wg0` or `flannel.1`.
