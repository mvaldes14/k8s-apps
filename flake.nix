{
  description = "K8s Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        inherit (pkgs) mkShell;
      in {
        devShells = {
          default = mkShell {
            buildInputs = with pkgs; [
              kubectl
              k9s
            ];
            shellHook = ''
              Commands available:
              - k8s
              - k9s
              - helm
            '';
          };
        };
      };
    };
}
