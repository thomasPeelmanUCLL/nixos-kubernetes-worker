# Calico Deployment and Troubleshooting

This guide documents how to deploy Calico on the NixOS Kubernetes cluster and how to recover from the two most common failures seen during setup.

## Prerequisites

- Control node: `k8s-control-1` at `10.1.1.237`
- Worker node: `k8s-worker-1` at `10.1.1.71`
- Kubernetes 1.36.3
- Calico manifests pinned to `v3.30.2`
- Calico CNI plugin package version `3.31.5` on the worker

## Worker CNI requirement

The Nix package `calico-cni-plugin` ships only `calico` and `install`. It does not ship `calico-ipam`. The Calico CNI configuration requires `calico-ipam` in `/opt/cni/bin`.

The worker's `modules/calico.nix` adds a `calicoIpam` package that links `calico-ipam` to `calico`:

```nix
calicoIpam = pkgs.runCommand "calico-ipam-link" { } ''
  mkdir -p $out/bin
  ln -s ${pkgs.calico-cni-plugin}/bin/calico $out/bin/calico-ipam
'';
```

This package is added to `services.kubernetes.kubelet.cni.packages` so NixOS links it into `/opt/cni/bin` on every rebuild.

Verify after a rebuild:

```bash
ls -l /opt/cni/bin/calico /opt/cni/bin/calico-ipam
```

Both should be symlinks into the Nix store.

## Firewall rules

Calico VXLAN requires UDP 4789 between nodes. The API server requires TCP 6443.

### Control node

`modules/worker-firewall.nix` accepts the following from the worker on `ens3`:

- `4789/udp` for VXLAN
- `5473/tcp` for Calico Typha
- `8888/tcp` for an existing service

`modules/control-plane.nix` opens `6443/tcp` on `ens3`.

### Worker node

`modules/control-firewall.nix` accepts the following from the control node on `ens3`:

- `10250/tcp` for kubelet
- `4789/udp` for VXLAN

Do not replace these scoped rules with global `allowedTCPPorts` or `allowedUDPPorts`.

## Deploy Calico

From the control node:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/calico.yaml
```

Wait for the DaemonSet and controller to be ready:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  -n kube-system rollout status daemonset/calico-node

sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  -n kube-system rollout status deployment/calico-kube-controllers
```

Check pod status:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  -n kube-system get pods -o wide
```

Both `calico-node` pods and `calico-kube-controllers` should be `1/1 Running`.

## Verify pod networking

Run a test pod on the worker:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig run nettest \
  --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeName":"k8s-worker-1"}}' -- sleep 3600

sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  wait --for=condition=Ready pod/nettest --timeout=90s
```

Then test connectivity:

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig exec nettest --"
$K ping -c2 -W2 10.1.1.71
$K ping -c2 -W2 10.1.1.237
$K ping -c2 -W2 10.244.206.194
$K wget -T3 -qO- --no-check-certificate https://10.1.1.237:6443/version
$K wget -T3 -qO- --no-check-certificate https://10.96.0.1:443/version
```

All pings should succeed. The wget commands may fail with a TLS alert because busybox wget does not trust the API server certificate. That is expected and does not indicate a routing failure.

Clean up:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig delete pod nettest
```

## Troubleshooting: calico-ipam missing

Symptom:

```text
failed to find plugin "calico-ipam" in path [/opt/cni/bin]
```

Cause:

The worker's `/opt/cni/bin/calico-ipam` is missing. The Nix package `calico-cni-plugin` does not provide it.

Fix:

Ensure the worker's `modules/calico.nix` includes the `calicoIpam` package in the CNI package list, then rebuild:

```bash
cd ~/nixos-kubernetes-worker
git pull
sudo nixos-rebuild switch --flake .
ls -l /opt/cni/bin/calico /opt/cni/bin/calico-ipam
```

Do not rely on a manual `ln -s` into `/opt/cni/bin`. A rebuild or kubelet restart can remove it.

## Troubleshooting: no route to host on service IP

Symptom:

```text
dial tcp 10.96.0.1:443: connect: no route to host
```

This affects pod-to-service traffic, not pod-to-node traffic.

Check kube-proxy on the worker:

```bash
systemctl status kube-proxy --no-pager
sudo journalctl -u kube-proxy -n 30 --no-pager
```

Check that the service DNAT rule exists:

```bash
sudo iptables-save -t nat | grep -A3 KUBE-SEP | grep 6443
```

Check that the pod can reach the API server directly:

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig exec nettest --"
$K wget -T3 -qO- --no-check-certificate https://10.1.1.237:6443/version
```

If the direct check works but the service IP fails, restart kube-proxy:

```bash
sudo systemctl restart kube-proxy
```

If the controller pod keeps crash-looping after kube-proxy is healthy, delete and recreate it. A stale conntrack entry or sandbox state from earlier failed starts can persist:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  -n kube-system delete pod -l k8s-app=calico-kube-controllers
```

## Notes

- Flannel and Calico must not run at the same time. The control node's `calico-vxlan-clean` branch disables flannel with `mkForce`.
- The worker's Calico CNI plugin version (3.31.5) may differ from the Calico manifest version (3.30.2). This is acceptable for a lab, but align them if you see CRD or API errors.
- The control node's `pod-api-access.nix` opens port 6443 on the `mynet` bridge, which is a Flannel-specific interface. It is not needed under Calico and can be removed once Flannel is fully gone.
