# Calico VXLAN migration (worker-side, Nix-native)

This repository now prepares `k8s-worker-1` for Calico CNI with pinned migration settings and no automatic in-cluster apply step. The PR is intentionally review-first: build and dry-activate only until you deliberately schedule cluster activation.

## Scope and safety

- Worker node: `k8s-worker-1` (`10.1.1.71`, interface `ens3`)
- Control node: `k8s-control-1` (`10.1.1.237`)
- Pod CIDR: `10.244.0.0/16` (IPv4)
- Service CIDR: `10.96.0.0/16`
- Calico migration settings are pinned to `v3.30.2` in `/etc/kubernetes/calico/node-settings-v3.30.2.yaml`.
- This change does **not** delete Flannel resources and does **not** run `kubectl apply` during activation.

## Build and dry-activation

Run from this checkout on the worker:

```sh
nix build --no-update-lock-file --out-link ./result .#nixosConfigurations.k8s-worker-1.config.system.build.toplevel
sudo ./result/bin/switch-to-configuration dry-activate
```

Review the dry-activation output before any switch/test activation.

## Controlled activation order

1. Prepare and review control-side Calico migration changes first (matching control repository PR #1).
2. Apply control-side changes in a maintenance window.
3. Apply this worker configuration with `nixos-rebuild test --flake .#k8s-worker-1`.
4. Confirm node readiness and pod networking behavior.
5. Persist with `nixos-rebuild switch --flake .#k8s-worker-1` only after verification.

Use declarative manifests/reconciliation on the control side as the primary deployment path. Keep one-off `kubectl` invocations as an emergency fallback, not the default workflow.

## Workload recreation after CNI cutover

After Calico is active, recreate workloads that still hold old Flannel network state:

- Restart affected Deployments/DaemonSets from the control node.
- Recreate long-lived standalone test pods.
- Confirm replacement pods receive `10.244.0.0/16` addresses and stable Service connectivity.

## Flannel removal sequencing

- Do not remove Flannel cluster resources in the same first activation step.
- Remove Flannel only after Calico dataplane validation succeeds across nodes.
- Keep rollback access until post-cutover checks pass.

## Verification checklist

From the control node:

```sh
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get ippools.crd.projectcalico.org
```

Validate:

- Worker remains `Ready`.
- Calico pool CIDR is `10.244.0.0/16`.
- VXLAN is enabled and BGP is disabled in the applied Calico resources.
- Calico node IP autodetection resolves to the worker `ens3` address (`10.1.1.71`).
- Existing IPv6 cluster behavior remains unchanged unless and until explicit IPv6 Calico resources are configured and tested.

## Rollback

If cutover fails:

1. Roll back to the previous worker system profile:
   - `sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch`
2. Revert control-side Calico changes according to the control runbook.
3. Keep Flannel resources in place until rollback validation completes.
