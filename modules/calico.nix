{ lib, pkgs, ... }:
let
  calicoVersion = "v3.30.2";
in
{
  # The pinned NixOS Kubernetes module does not expose first-class Calico
  # cluster deployment options, so this module declares the worker-side CNI
  # state and writes pinned Calico node settings for controlled activation.
  services.kubernetes.kubelet.cni.packages = lib.mkForce [
    pkgs.cni-plugins
    pkgs.calico-cni-plugin
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
