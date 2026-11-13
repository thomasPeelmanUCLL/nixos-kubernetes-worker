{ config, lib, pkgs, ... }:
let
  control4 = "10.1.1.237";
  worker4 = "10.1.1.71";
  rules = [
    "${pkgs.iptables}/bin/iptables -w -A nixos-fw -i ens3 -s ${control4}/32 -d ${worker4}/32 -p tcp --dport 10250 -j nixos-fw-accept"
    "${pkgs.iptables}/bin/iptables -w -A nixos-fw -i ens3 -s ${control4}/32 -d ${worker4}/32 -p udp --dport 4789 -j nixos-fw-accept"
    "${pkgs.iptables}/bin/iptables -w -A OUTPUT -o ens3 -s ${worker4}/32 -d ${control4}/32 -p tcp --dport 5473 -j ACCEPT"
  ];
in
{
  # Preserve SSH. Accept kubelet and VXLAN traffic only from the control
  # node, not arbitrary hosts on the private network.
  networking.firewall.extraCommands = lib.concatStringsSep "\n" rules;
  networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n"
    (rule: (builtins.replaceStrings [ "-A nixos-fw" "-A OUTPUT" ] [ "-D nixos-fw" "-D OUTPUT" ] rule) + " || true")
    rules;

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
