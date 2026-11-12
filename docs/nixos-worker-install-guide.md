# CloudStack NixOS worker: copy-paste base installation

Prepared for the existing native NixOS Kubernetes lab, 2026-11-12.

## Scope and safety

This guide installs **base NixOS** on a NEW worker VM named `k8s-worker-1`.
It does NOT join the VM to Kubernetes yet. Joining requires the worker's actual
IPv4/IPv6 addresses, restricted control-to-worker firewall rules, and secure
certificate enrollment. Never copy the control node's etcd data, private keys,
admin kubeconfig, hardware UUID, or `roles = [ "master" ]` to the worker.

The existing control API is `https://10.1.1.237:6443`. Leave that VM alone.
Its reboot checks confirmed its configured addresses and no failed systemd
units; final post-reboot API/node/DNS checks were not supplied in this session.

These disk commands are ONLY for a fresh VM with legacy BIOS and `/dev/sda`.
They erase that disk. Stop if the VM uses UEFI, a different disk, or has data
to preserve. Run the blocks in order, on the stated machine, and stop at errors.
Do not paste the entire document as one script.

## 1. Create the NEW worker VM in CloudStack

- Name: `k8s-worker-1` (keep the control node running).
- Use the same reachable private network as `10.1.1.237` and provide IPv6.
- Suggested lab starting resources: 2 or more vCPUs, 4 GB or more RAM,
  and 32 GB or more disk. Actual workload requirements may be higher.
- Attach the NixOS minimal ISO, and use legacy BIOS for this exact guide.
- Open its console and boot the ISO.

## 2. Inspect the worker from the ISO

```bash
hostname
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
ip -brief address
ip route
if [ -d /sys/firmware/efi ]; then
  echo 'STOP: UEFI boot; do not use the BIOS partition commands below.'
else
  echo 'Legacy BIOS boot: continue only after checking the target disk.'
fi
```

Verify this is the NEW worker, not `k8s-control-1`. Verify the target is `/dev/sda`.
If there are unexpected partitions or existing filesystems, stop and inspect.

## 3. Partition and format ONLY the new worker disk

The guarded block asks for an explicit confirmation. It refuses UEFI and a
mounted `/dev/sda` disk. This is not a substitute for verifying VM identity.

```bash
bash <<'SCRIPT'
set -euo pipefail
if [ -d /sys/firmware/efi ]; then
  echo 'STOP: this guide requires legacy BIOS.'
  exit 1
fi
[ -b /dev/sda ] || { echo 'STOP: /dev/sda does not exist.'; exit 1; }
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS /dev/sda
if lsblk -nr -o MOUNTPOINTS /dev/sda | grep -q '[^[:space:]]'; then
  echo 'STOP: this disk or a partition is mounted.'
  exit 1
fi
printf 'ERASE /dev/sda on the NEW WORKER ONLY. Type ERASE-WORKER: ' >/dev/tty
read -r answer </dev/tty
[ "$answer" = 'ERASE-WORKER' ] || { echo 'Cancelled.'; exit 1; }
sudo parted /dev/sda --script -- mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on
sudo partprobe /dev/sda
sudo udevadm settle
sudo mkfs.ext4 -L nixos /dev/sda1
sudo mkdir -p /mnt
sudo mount /dev/sda1 /mnt
findmnt --mountpoint /mnt
SCRIPT
```

Expected mount: `/mnt /dev/sda1 ext4 ...`.
Do not rerun this block after it succeeds. If only mounting failed, inspect and
mount the existing partition; do not format again.

## 4. Generate the correct hardware configuration

Mount first, generate second. Generating before mounting caused the missing
root-filesystem issue during the previous installation.

```bash
sudo nixos-generate-config --root /mnt
cat /mnt/etc/nixos/hardware-configuration.nix
```

Verify it contains `fileSystems."/"` with THIS worker disk's UUID and `ext4`.
Do not type a UUID from another machine or copy a screenshot transcription.

```bash
nix-instantiate --parse /mnt/etc/nixos/hardware-configuration.nix >/dev/null && echo 'Hardware syntax OK'
```

## 5. Write the base worker configuration

The public key below is the existing key from the control repository's
`modules/base.nix`. Use it only if you own its matching private key. Otherwise
replace that public-key line with your actual workstation PUBLIC key before
installation. Never paste a private key or a GitHub token into this file.

```bash
sudo tee /mnt/etc/nixos/configuration.nix >/dev/null <<'EOF'
{ pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "k8s-worker-1";
  networking.networkmanager.enable = true;

  users.users.tom = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKwIqtxiBKnQ5Vz8UVnA9go4eF2++FzX3Upnm/p+EitH eddsa-key-20261031"
    ];
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      AllowUsers = [ "tom" ];
      PubkeyAuthentication = true;
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [ git curl wget nano ];
  system.stateVersion = "26.05";
}
EOF
```

This is a base installation using the ISO's configured nixpkgs source, not yet
the cluster's pinned worker flake. It deliberately enables no Kubernetes role,
no etcd and no API server. No swap is configured in this simple layout.

## 6. Install, set passwords, then power off

```bash
sudo nixos-install --root /mnt
```

Wait for success. Set a strong root password when prompted. Root SSH is disabled.
If installation fails, stop and retain the error; do not reboot.

After successful installation, set `tom`'s console/sudo password:

```bash
sudo nixos-enter --root /mnt -c 'passwd tom'
```

Then:

```bash
sudo poweroff
```

Detach the ISO in CloudStack, or set disk-first boot, and start the worker VM.

## 7. Verify the INSTALLED worker

Log in through the console as `tom` using the password just set.

```bash
hostname
findmnt /
nixos-version
ip -brief address
ip -6 address show dev ens3 scope global
ip -6 route show default
free -h
sudo systemctl --failed --no-pager
```

Expected: hostname `k8s-worker-1`, root on `/dev/sda1`, no failed units.
If the NIC is not named `ens3`, use the name shown by `ip -brief address` and
report it; do not force a configuration that assumes another interface.
Use a non-temporary IPv6 address for future node configuration, and verify
address persistence after a later reboot. Dynamic does not mean permanently fixed.

## 8. Test API reachability from the worker

```bash
curl --connect-timeout 5 --max-time 10 --insecure \
  --silent --show-error --output /dev/null --write-out 'HTTP %{http_code}\n' \
  https://10.1.1.237:6443/version
```

An HTTP response (including 401/403) confirms transport reachability. Timeout,
connection refusal, or HTTP 000 needs investigation. `--insecure` is ONLY for
this reachability test; worker enrollment must verify the real cluster CA.

## 9. Optional: SSH from your workstation

Replace WORKER_IPV4 with the worker's actual private address. The workstation
must have a network route to it and the matching private SSH key.

```bash
ssh tom@WORKER_IPV4
```

Do not copy the workstation's private key onto either VM.

## 10. Stop here for Kubernetes enrollment

The existing private GitHub repository is:
`thomasPeelmanUCLL/nixos-kubernetes-worker`.
At inspection it contained only README.md, not a deployable worker configuration.
There is therefore no existing worker flake to apply safely yet.

Send the output from section 7 and the API reachability result. These provide
the actual worker IPv4, non-temporary IPv6, NIC and disk layout.

The next configuration must:
- use native NixOS Kubernetes worker role, NOT kubeadm, K3s or the master role;
- pin nixpkgs to `7dcdd87373d72e7a2173e4db02e20d3d7f495cfd` to match the control node;
- point to the existing API `10.1.1.237:6443`;
- enroll worker certificates securely, keeping bootstrap tokens out of Git;
- configure matching dual-stack Flannel networks and restricted inter-node
  VXLAN/kubelet access on both nodes;
- avoid exposing the CFSSL issuer publicly (currently private-bound and filtered);
- let the controller allocate the worker's pod CIDRs, not reuse the control's
  `10.244.0.0/24` / `fd73:7ab4:1c90:100::/64` allocation;
- test worker pod scheduling, cross-node IPv4/IPv6 pod and Service traffic,
  DNS and reboot recovery before calling the worker validated.

Do not make either private repository public to bypass clone authentication.
HTTPS cloning of private repositories needs an authorized token; passwords do
not work. If cloning later, enter the token at the password prompt, never in
shell commands or chat.

## Control-node reminder

The replacement control-node hardware UUID and addresses were changed locally
but have not been committed to GitHub in this session. Do not reset or discard
those changes. Merely running `git pull` will not save them remotely.

## Sources

- NixOS manual: https://nixos.org/manual/nixos/stable/index.html
- Existing control repository (private): https://github.com/thomasPeelmanUCLL/nixos-kubernetes-control
- Existing worker repository (private): https://github.com/thomasPeelmanUCLL/nixos-kubernetes-worker

The base-install sequence follows NixOS manual installation: partition, format,
mount the target, generate configuration, configure GRUB, install, and set passwords.
