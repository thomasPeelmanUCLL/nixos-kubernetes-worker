{
  description = "NixOS native Kubernetes worker on CloudStack";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.k8s-worker-1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ./modules/worker.nix
        ./modules/calico.nix
        ./modules/control-firewall.nix
      ];
    };
  };
}
