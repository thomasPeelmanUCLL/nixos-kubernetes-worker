# Calico Deployment and Troubleshooting

This guide documents how to deploy Calico on the NixOS Kubernetes cluster and how to recover from common failures seen during setup.

## Current status

The cluster is running Calico successfully:

- Control node: `k8s-control-1` at `10.1.1.237`, status `Ready`
- Worker node: `k8s-worker-1` at `10.1.1.71`, status `Ready`
- Kubernetes 1.36.3
- Calico manifests and CNI plugin both pinned to `v3.30.2`
- `calico-node` DaemonSet: 2/2 pods Running
- `calico-kube-controllers`: 1/1 Running
- `coredns`: 1/1 Running
- Flannel is fully removed; `flannel.1` no longer exists

## Worker CNI pinning

The worker pins the Calico CNI plugin to match the Calico manifest version (`v3.30.2`). This is done in `modules/calico.nix` with an `overrideAttrs` that sets both the source revision and the Go module hash:

```nix
calico-cni-plugin = pkgs.calico-cni-plugin.overrideAttrs (old: rec {
  version = "3.30.2";
  src = pkgs.fetchFromGitHub {
    owner = "projectcalico";
    repo = "calico";
    rev = "v${version}";
    hash = "sha256-UvHrCA/1n9dklcMY1AfNNW5/TtxVdmwmQb2DHEBFZhA=";
  };
  vendorHash = "sha256-Cp1Eo8Xa4c0o5l6/p+pyHa/t3jMUpgUDDXEAKwS6aCE=";
});
```

Both `hash` (source tarball) and `vendorHash` (Go module dependencies) must match the pinned version. If either is wrong, Nix reports a hash mismatch during `nixos-rebuild build`.

The `calicoIpam` derivation links `calico-ipam` to the `calico` binary, since the Nix package ships only `calico` and `install`:

```nix
calicoIpam = pkgs.runCommand "calico-ipam-link" { } ''
  mkdir -p $out/bin
  ln -s ${calico-cni-plugin}/bin/calico $out/bin/calico-ipam
'';
```

Verify after a rebuild:

```bash
ls -l /opt/cni/bin/calico /opt/cni/bin/calico-ipam
```

## kubectl access

The admin kubeconfig lives at `/etc/kubernetes/cluster-admin.kubeconfig`, not `admin.conf`. It references a client key at `/var/lib/kubernetes/secrets/cluster-admin-key.pem` that is root-owned with `600` permissions.

Two ways to use kubectl:

Run as root (no permission changes needed):

```bash
sudo KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig kubectl get nodes
sudo KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig kubectl get pods -n kube-system
```

Or, for a lab environment, copy the kubeconfig and relax the key permission:

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/cluster-admin.kubeconfig ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
sudo chmod 644 /var/lib/kubernetes/secrets/cluster-admin-key.pem
kubectl get nodes
```

Note: relaxing the key permission to `644` is acceptable for a lab but not recommended for production. Prefer `sudo` or a scoped user kubeconfig instead.

## Firewall rules

Calico VXLAN requires UDP 4789 between nodes. The API server requires TCP 6443.

### Control node

`modules/worker-firewall.nix` accepts the following from the worker on `ens3`:

- `4789/udp` for VXLAN
- `5473/tcp` for Calico Typha
- `8888/tcp` for an existing service

`modules/control-plane.nix` opens `6443/tcp` on `ens3`.

### Worker node

`modules/control-firewall.nix` accepts the following from the worker on `ens3`:

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
$K wget -T3 -qO- --no-check-certificate https://10.1.1.237:6443/version
$K wget -T3 -qO- --no-check-certificate https://10.96.0.1:443/version
```

All pings should succeed. The wget commands may fail with a TLS alert because busybox wget does not trust the API server certificate. That is expected and does not indicate a routing failure.

Clean up:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig delete pod nettest
```

## Troubleshooting: hash mismatch during build

Symptom:

```text
error: hash mismatch in fixed-output derivation
```

Cause:

Either the source `hash` or the `vendorHash` in `modules/calico.nix` does not match the pinned Calico version.

Fix:

Nix prints the expected hash in the error output (`got: sha256-...`). Copy that value into the corresponding field (`hash` for the source tarball, `vendorHash` for Go modules) and rebuild.

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

If the direct node check works but the service IP fails, restart kube-proxy:

```bash
sudo systemctl restart kube-proxy
```

If the controller pod keeps crash-looping after kube-proxy is healthy, delete and recreate it:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig \
  -n kube-system delete pod -l k8s-app=calico-kube-controllers
```

## Notes

- Flannel and Calico must not run at the same time. The control node's `calico-vxlan-clean` branch disables flannel with `mkForce`.
- The worker's Calico CNI plugin is now pinned to 3.30.2, matching the Calico manifest version, via `overrideAttrs` with both `hash` and `vendorHash`.
- The control node's `pod-api-access.nix` opens port 6443 on the `mynet` bridge, which is a Flannel-specific interface. It is not needed under Calico and can be removed once Flannel is fully gone.
