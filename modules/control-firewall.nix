{ config, lib, pkgs, ... }:
let
  control4 = "10.1.1.237";
  control6 = "2001:6a8:2880:1483:e632:18bb:42b5:3671";
  worker4 = "10.1.1.71";
  worker6 = "2001:6a8:2880:1483:7145:4d72:a74d:4a32";
  rules = [
    "${pkgs.iptables}/bin/iptables -w -A nixos-fw -i ens3 -s ${control4}/32 -d ${worker4}/32 -p tcp --dport 10250 -j nixos-fw-accept"
    "${pkgs.iptables}/bin/iptables -w -A nixos-fw -i ens3 -s ${control4}/32 -d ${worker4}/32 -p udp --dport 8472 -j nixos-fw-accept"
    "${pkgs.iptables}/bin/ip6tables -w -A nixos-fw -i ens3 -s ${control6}/128 -d ${worker6}/128 -p udp --dport 8472 -j nixos-fw-accept"
  ];
in
{
  # Preserve SSH. Accept kubelet and VXLAN traffic only from the control
  # node, not arbitrary hosts on the private or global IPv6 networks.
  networking.firewall.extraCommands = lib.concatStringsSep "\n" rules;
  networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n"
    (rule: (builtins.replaceStrings [ "-A nixos-fw" ] [ "-D nixos-fw" ] rule) + " || true")
    rules;

  systemd.services.flannel.environment.FLANNELD_PUBLIC_IPV6 = worker6;

  assertions = [
    {
      assertion = !config.networking.nftables.enable;
      message = "control-firewall.nix requires the NixOS iptables firewall backend; review rules before enabling nftables.";
    }
    {
      assertion = config.networking.firewall.enable;
      message = "The cluster firewall rules require networking.firewall.enable.";
    }
  ];
}
