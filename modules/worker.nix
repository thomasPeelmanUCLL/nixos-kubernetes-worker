{ config, lib, pkgs, ... }:
let
  control4 = "10.1.1.237";
  node4 = "10.1.1.71";
  # Verify this is a stable, non-temporary address before activation.
  node6 = "2001:6a8:2880:1483:7145:4d72:a74d:4a32";
  pods4 = "10.244.0.0/16";
  pods6 = "fd73:7ab4:1c90:100::/56";
in
{
  # Build-review configuration. Peer-restricted firewall rules must be
  # added on both nodes before activation. Do not deploy this alone.
  networking.extraHosts = ''
    ${control4} k8s-control-1
    ${node4} k8s-worker-1
  '';

  networking.networkmanager.unmanaged = [
    "interface-name:flannel*"
    "interface-name:mynet"
  ];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv6.conf.default.accept_ra" = 2;
    "net.ipv6.conf.ens3.accept_ra" = 2;
  };

  services.kubernetes = {
    package = pkgs.kubernetes;
    roles = [ "node" ];
    masterAddress = "k8s-control-1";
    apiserverAddress = "https://${control4}:6443";
    clusterCidr = "${pods4},${pods6}";
    easyCerts = true;
    pki.pkiTrustOnBootstrap = false;
    addons.dns.enable = false;

    kubelet = {
      address = node4;
      nodeIp = "${node4},${node6}";
      clusterDns = [ "10.96.0.10" ];
      unschedulable = true;
    };

    flannel = {
      enable = true;
      openFirewallPorts = false;
    };
  };

  services.flannel = {
    iface = "ens3";
    publicIp = node4;
    network = lib.mkForce pods4;
    extraNetworkConfig = {
      EnableIPv4 = true;
      EnableIPv6 = true;
      IPv6Network = pods6;
      IPv6SubnetLen = 64;
    };
  };
  systemd.services.flannel.environment.FLANNELD_IP_MASQ = "true";

  # Keep secret contents outside Git and the Nix store. Fail bootstrap
  # rather than downloading a CA with certificate verification disabled.
  systemd.services.kube-certmgr-bootstrap.preStart = ''
    test -s /var/lib/kubernetes/secrets/ca.pem
    test -s /var/lib/kubernetes/secrets/apitoken.secret
  '';

  assertions = [
    {
      assertion = config.services.kubernetes.package.version == "1.36.3";
      message = "This worker targets Kubernetes 1.36.3; review before changing the package version.";
    }
  ];
}
