# Handover: Next Steps for the NixOS Kubernetes Cluster

This document captures the current state of the new NixOS-native Kubernetes cluster and the prioritized list of components needed to reach feature parity with the existing production cluster (`trip`).

## Current state (verified 2026-11-15)

The new cluster is a working bare control plane with CNI and DNS:

- Control node: `k8s-control-1` at `10.1.1.237`, status `Ready`
- Worker node: `k8s-worker-1` at `10.1.1.71`, status `Ready`
- Kubernetes 1.36.3
- Calico 3.30.2 (manifests and CNI plugin both pinned, matching versions)
- CoreDNS running
- Flannel fully removed; `flannel.1` no longer exists
- All Calico and CoreDNS pods `Running`

Repositories:
- Worker: `thomasPeelmanUCLL/nixos-kubernetes-worker` (branch `nix-native-calico-cleanup`)
- Control: `thomasPeelmanUCLL/nixos-kubernetes-control`

## Reference: the old cluster (`trip`)

The old cluster is a full production-grade setup running on a separate host (`thomas@trip`). It includes:

- ArgoCD (GitOps)
- cert-manager (with CRDs)
- ingress-nginx
- metrics-server
- kubernetes-dashboard
- local-path-provisioner
- cloud-controller-manager
- Netbird
- Multiple workloads: n8n, inventory app, iswleuven, shores-of-ebaria
- Calico CNI (already, so CNI parity is achieved)

## Gap analysis: new cluster vs old cluster

| Component | Old cluster | New cluster | Status |
|---|---|---|---|
| Control plane | Yes | Yes | Parity |
| CNI | Calico | Calico 3.30.2 | Parity |
| DNS | CoreDNS | CoreDNS | Parity |
| kube-proxy | Yes | Yes | Parity |
| Ingress controller | ingress-nginx | None | Missing |
| cert-manager | Yes | None | Missing |
| Metrics server | Yes | None | Missing |
| GitOps | ArgoCD | None | Missing |
| Dashboard | kubernetes-dashboard | None | Missing |
| Local storage | local-path-provisioner | None | Missing |
| Cloud integration | cloud-controller-manager | None | Missing (may not be needed) |
| Netbird | Yes | None | Missing (optional) |
| Workloads | Multiple apps | None | Missing |

## Prioritized roadmap to parity

1. **metrics-server** — needed for `kubectl top` and HPA; smallest, quickest win.
2. **local-path-provisioner** — needed for any workload with persistent storage (e.g. n8n-postgres).
3. **ingress-nginx** — needed to expose HTTP services.
4. **cert-manager** — needed for TLS/Let's Encrypt.
5. **ArgoCD** — GitOps; optional if Nix-native deployment is preferred instead.
6. **kubernetes-dashboard** — optional, nice-to-have.

## Deployment approach decision

Two paths to close the gap:

- **Reuse Helm charts** from the old cluster's repos (`k8s-grafana`, `k8s-cert-manager`, `k8s-prometheus`) — fastest, familiar tooling.
- **Go Nix-native** — more reproducible, but more work; fits the existing flake-based approach.

Decision needed before starting: Helm reuse or full Nix-native.

## kubectl access (control node)

The admin kubeconfig is at `/etc/kubernetes/cluster-admin.kubeconfig`. The client key at `/var/lib/kubernetes/secrets/cluster-admin-key.pem` is root-owned with `600` permissions.

Run as root:

```bash
sudo KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig kubectl get nodes
sudo KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig kubectl get pods -A
```

Or, for lab use, copy kubeconfig and relax key permission:

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/cluster-admin.kubeconfig ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
sudo chmod 644 /var/lib/kubernetes/secrets/cluster-admin-key.pem
kubectl get nodes
```

## Verification commands (run after each new component)

```bash
kubectl get nodes
kubectl get pods -A
kubectl get crd | grep -E "cert-manager|prometheus|grafana|alertmanager|ingress"
```

## Notes

- Secrets/PKI currently uses `easyCerts = true` plus a manually managed kubeconfig. sops-nix/agenix was considered but deferred as not needed for now.
- The Calico CNI plugin is pinned to 3.30.2 via `overrideAttrs` with both `hash` and `vendorHash` in `modules/calico.nix`.
- See `docs/calico-deployment.md` for the full Calico deployment and troubleshooting guide.
