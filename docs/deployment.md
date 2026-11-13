# Worker deployment runbook

## Current deployment

Verified configuration revision: `778e14bbe478d5cb6862d69c316621362a100b5f`.

Observed running and boot-default system: `/nix/store/451hd9l9hxj98wn5afyzryxbd0hdwyf8-nixos-system-k8s-worker-1-26.05.20261102.7dcdd87`.

Node: k8s-worker-1, ens3, 10.1.1.71, 2001:6a8:2880:1483:7145:4d72:a74d:4a32. Control: k8s-control-1 at 10.1.1.237. Global IPv6 addresses are dynamically renewed; maintain stable assignments and update configuration if they change.

From the workstation, SSH uses `ssh -i ~/.ssh/id_isw -o IdentitiesOnly=yes -p 1223 tom@193.191.187.103`. The control node uses the same public address on port 1222. Do not run workstation-key commands from the servers or copy that private key to them.

## First enrollment

Prerequisites: working NixOS installation, correct machine-specific hardware-configuration.nix, working SSH/sudo access, reviewed authorized key and peer firewall settings, and the control node online. This repository does not install or partition a blank machine.

Securely obtain the CA and enrollment token from the trusted control node. On the worker install:

- /var/lib/kubernetes/secrets/ca.pem: root:root, mode 0644.
- /var/lib/kubernetes/secrets/apitoken.secret: root:root, mode 0600.

Create their directory with mode 0755. Never commit these transfer files or secret contents. Never transfer the CA private key. The configuration disables trust-on-bootstrap and fails certificate bootstrap when either required file is missing or empty.

Verify the issuer without disabling TLS verification:

```sh
curl --connect-timeout 5 --max-time 10 --cacert /var/lib/kubernetes/secrets/ca.pem --resolve k8s-control-1:8888:10.1.1.237 --header 'Content-Type: application/json' --data '{}' --silent --show-error --output /dev/null --write-out 'HTTP %{http_code}\n' https://k8s-control-1:8888/api/v1/cfssl/info
```

Expected HTTP 200. This does not validate the enrollment token; successful certificate issuance and node registration are separate checks.

## Repeat deployment

1. Fetch and select an explicit repository revision on the workstation.
2. Export tracked source: `git archive REVISION > worker-source.tar`.
3. Copy source: `scp -i ~/.ssh/id_isw -o IdentitiesOnly=yes -P 1223 worker-source.tar tom@193.191.187.103:/home/tom/`.
4. On the worker, extract into a new mktemp directory; never reset an existing dirty checkout.
5. Build and preview using the README commands, then apply the reviewed flake.

Destination-side builds avoid the unsigned-store-path rejection encountered when copying a locally built workstation closure. Do not disable signature checks or add broad trusted users as a shortcut. Keep secrets and /var/lib/kubernetes across routine updates.

For network-sensitive changes capture the resolved old /run/current-system, schedule its switch-to-configuration test with systemd-run --on-active=10m, then test-activate the new result. Verify a fresh workstation SSH connection and node health before cancelling the timer and persisting with nixos-rebuild switch. Rollback is best-effort; keep console recovery available.

Compare `readlink -f /run/current-system` with `readlink -f /nix/var/nix/profiles/system` after switching. They should match. Check `systemctl is-active NetworkManager firewall containerd certmgr kubelet kube-proxy` plus the currently selected CNI path (`flannel` before Calico cutover, Calico services/pods after cutover), then `systemctl --failed`.

## Scheduling and cluster verification

Use kubectl and /etc/kubernetes/cluster-admin.kubeconfig on the control node, not on this worker. Do not copy cluster-admin credentials here.

The worker declares kubelet.unschedulable = false. The pinned NixOS module implements true as the custom unschedulable=true:NoSchedule registration taint, not Node.spec.unschedulable. An old taint may remain after changing registration settings. Inspect the live worker and, only when appropriate, remove that specific taint from the control node with `kubectl taint nodes k8s-worker-1 unschedulable:NoSchedule-`. Leave the control node's restrictions intact.

Verify Ready status, both registered node IPs, IPv4/IPv6 pod CIDRs, scheduler placement of an ordinary pod, DNS from that pod, cross-node pod traffic, and HTTP through both ClusterIPs of a RequireDualStack Service. Do not hard-code ephemeral test addresses.

The control node must resolve k8s-worker-1 for API-server kubelet exec/logs connections; its modules/worker-hostname.nix supplies the mapping. Cross-node networking passing does not by itself prove this management path works.

## Scope and cleanup

CoreDNS manifests and the cluster runbook live in the control repository and are applied separately from NixOS. The temporary k8s-netcheck namespace was used for tests; cleanup was suggested but not confirmed. Inspect before deleting it. Keep enrollment credentials and generated PKI in place until a deliberate, backed-up decommissioning.

Verified lab behavior is not a guarantee of HA, storage durability, external IPv6 egress, post-reboot recovery, network-policy enforcement, or production security. The existing machine-specific configuration is not safe to copy unchanged to another node.
