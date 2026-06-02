# RKE2 on sp-vm nodes

Configuration is written at runtime by the Swarm `rke2` provision plugin
(`cni: canal`, WireGuard `rke2-canal-config.yaml`, ingress NodePort, etc.).

Do not bake `cni: cilium` or other CNI settings into the image.
