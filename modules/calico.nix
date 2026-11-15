{ lib, pkgs, ... }:
let
  calicoVersion = "v3.30.2";

  # Pin the Calico CNI plugin to match calicoVersion. nixpkgs may carry a
  # newer calico-cni-plugin; overriding version keeps the CNI plugin, IPAM
  # plugin, and Calico manifests on the same release line.
  calico-cni-plugin = pkgs.calico-cni-plugin.overrideAttrs (old: rec {
    version = "3.30.2";
    src = pkgs.fetchFromGitHub {
      owner = "projectcalico";
      repo = "calico";
      rev = "v${version}";
      hash = "sha256-UvHrCA/1n9dklcMY1AfNNW5/TtxVdmwmQb2DHEBFZhA=";
    };
  });

  # pkgs.calico-cni-plugin ships only `calico` and `install`. Calico selects
  # its CNI/IPAM role from the name it is invoked as, so calico-ipam is a
  # link to the calico binary (same layout as the upstream calico/cni image).
  calicoIpam = pkgs.runCommand "calico-ipam-link" { } ''
    mkdir -p $out/bin
    ln -s ${calico-cni-plugin}/bin/calico $out/bin/calico-ipam
  '';
in
{
  # The pinned NixOS Kubernetes module does not expose first-class Calico
  # cluster deployment options, so this module declares the worker-side CNI
  # state and writes pinned Calico node settings for controlled activation.
  services.kubernetes.kubelet.cni.packages = lib.mkForce [
    pkgs.cni-plugins
    calico-cni-plugin
    calicoIpam
  ];

  # Do not declare portmap here. The NixOS kubelet CNI module writes each
  # configured plugin as a separate CNI network file, and a standalone
  # portmap configuration is invalid because it has no network name.
  # Calico's install-cni init container installs the combined
  # calico + portmap CNI configuration.
  services.kubernetes.kubelet.cni.config = lib.mkForce [
    {
      type = "calico";
      cniVersion = "0.3.1";
      name = "k8s-pod-network";

      log_level = "info";
      datastore_type = "kubernetes";
      policy.type = "k8s";
      ipam.type = "calico-ipam";
      kubernetes.kubeconfig = "/etc/cni/net.d/calico-kubeconfig";
    }
  ];

  environment.etc."kubernetes/calico/node-settings-${calicoVersion}.yaml".text = ''
    # Pinned node-side Calico settings for controlled activation from the control node.
    calicoVersion: ${calicoVersion}
    ipPools:
      - cidr: 10.244.0.0/16
        encapsulation: VXLAN
        natOutgoing: Enabled
    bgp: Disabled
    nodeAddressAutodetectionV4:
      interface: "ens3"
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/kubelet/plugins_registry 0755 root root -"
  ];
}
