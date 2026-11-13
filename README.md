# NixOS Kubernetes worker

Machine-specific configuration for k8s-worker-1 in the verified CloudStack dual-stack lab. For a different machine, replace the hardware configuration, SSH authorized key, node addresses, interface, and peer addresses before deployment.

## Verified 2026-11-13

- Kubernetes 1.36.3; worker Ready at private IPv4 10.1.1.71.
- Ordinary scheduler-selected workload ran on the worker.
- IPv4/IPv6 pod traffic passed between control and worker in both directions.
- HTTP passed through both IP families of a Service and its DNS name.
- Worker DNS resolved kubernetes.default.svc.cluster.local.
- Running system and persistent system profile matched; kubelet had no initial unschedulable registration taint.

Configuration revision tested: `778e14bbe478d5cb6862d69c316621362a100b5f`.

See [deployment runbook](docs/deployment.md). The matching control repository is `thomasPeelmanUCLL/nixos-kubernetes-control`; cluster-wide CoreDNS manifests live there.

## Short local workflow

Run inside the intended checkout on the worker, after installing enrollment secrets:

```sh
nix build --no-update-lock-file --out-link ./result .#nixosConfigurations.k8s-worker-1.config.system.build.toplevel
sudo ./result/bin/switch-to-configuration dry-activate
# Review the preview; use test activation and rollback protection for risky changes.
sudo nixos-rebuild switch --flake .#k8s-worker-1
```

The flake imports configuration.nix, the machine's hardware configuration, modules/worker.nix, modules/calico.nix, and modules/control-firewall.nix. Do not rebuild from the unrelated minimal /etc/nixos configuration. Secrets are not stored in Git. Lab configuration; reboot recovery and production hardening were not validated.
